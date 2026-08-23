defmodule Agentix.TelemetryTest.CrashProvider do
  @moduledoc false
  # Opens successfully, then raises during enumeration — the span must end in
  # :exception (and the turn in {:turn_failed, ...}), never in :stop.
  @behaviour Agentix.Provider

  alias ReqLLM.Message

  @impl true
  def stream(_model, _context, _opts) do
    chunks =
      Stream.resource(
        fn -> :boom end,
        fn :boom -> raise "provider crashed mid-stream" end,
        fn _ -> :ok end
      )

    {:ok,
     %Agentix.Provider.Stream{
       chunks: chunks,
       cancel: fn -> :ok end,
       finalize: fn -> {%Message{role: :assistant, content: []}, %{}} end
     }}
  end
end

defmodule Agentix.TelemetryTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope
  alias Agentix.Telemetry
  alias Agentix.TelemetryTest.CrashProvider
  alias Agentix.Test.MockProvider
  alias ReqLLM.Context
  alias ReqLLM.Message

  @fast_retry %{max_attempts: 3, base_ms: 1, max_ms: 5}

  @model_call_events [
    [:agentix, :model_call, :start],
    [:agentix, :model_call, :stop],
    [:agentix, :model_call, :exception]
  ]

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))

    handler_ref = :telemetry_test.attach_event_handlers(self(), @model_call_events)
    {:ok, id: id, ref: handler_ref}
  end

  defp config(opts \\ []), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  describe "[:agentix, :model_call] spans" do
    test "a retried turn emits one span per attempt", %{id: id, ref: ref} do
      usage = %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      MockProvider.script([error(503), error(503), completion("recovered", usage: usage)])
      {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: @fast_retry))

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      # Attempts 1 and 2: start → exception (the open failed pre-stream).
      for attempt <- [1, 2] do
        assert_receive {[:agentix, :model_call, :start], ^ref, %{system_time: _},
                        %{conversation_id: ^id, attempt: ^attempt, model: "mock:test"}}

        assert_receive {[:agentix, :model_call, :exception], ^ref, %{duration: _},
                        %{attempt: ^attempt, kind: :error, reason: reason, stacktrace: trace}}

        assert %Telemetry.StreamOpenError{reason: %{status: 503}} = reason
        assert is_list(trace)
      end

      # Attempt 3: start → stop with the usage measurements and the assembled response.
      assert_receive {[:agentix, :model_call, :start], ^ref, _measurements,
                      %{attempt: 3, turn_ref: turn_ref, context: %Context{}, system_call?: false}}

      assert_receive {[:agentix, :model_call, :stop], ^ref, measurements, metadata}

      assert %{input_tokens: 10, output_tokens: 5, total_tokens: 15, cached_tokens: nil} =
               measurements

      assert is_integer(measurements.duration)
      assert is_integer(measurements.latency_ms) and measurements.latency_ms >= 0

      assert %{attempt: 3, conversation_id: ^id, turn_ref: ^turn_ref, usage: ^usage} = metadata
      assert %Message{role: :assistant} = metadata.response
      assert metadata.finish_reason == :stop
      refute_receive {[:agentix, :model_call, :start], ^ref, _, _}, 30
    end

    test "missing usage yields nil token measurements, never a crash", %{id: id, ref: ref} do
      MockProvider.script(completion("hi"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :model_call, :stop], ^ref, measurements, %{usage: %{}}}

      assert %{input_tokens: nil, output_tokens: nil, total_tokens: nil, cached_tokens: nil} =
               measurements
    end

    test "a mid-stream provider crash ends the span in :exception", %{id: id, ref: ref} do
      Application.put_env(:agentix, :provider, CrashProvider)
      on_exit(fn -> Application.put_env(:agentix, :provider, MockProvider) end)

      {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: false))
      :ok = Conversation.send_message(id, "Hi", Scope.new())

      assert_receive {[:agentix, :model_call, :start], ^ref, _measurements, %{attempt: 1}}

      assert_receive {[:agentix, :model_call, :exception], ^ref, %{duration: _},
                      %{kind: :error, reason: %RuntimeError{}}}

      assert_receive {:turn_failed, _turn_ref, _reason}
      refute_receive {[:agentix, :model_call, :stop], ^ref, _, _}, 30
    end

    test "metadata never exposes scope internals", %{id: id, ref: ref} do
      MockProvider.script(completion("hi"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      scope = Scope.new(current_user: %{email: "victim@example.com"}, assigns: %{token: "s3cr3t"})
      :ok = Conversation.send_message(id, "Hi", scope)
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :model_call, :start], ^ref, _measurements, metadata}
      refute Map.has_key?(metadata, :scope)
      refute inspect(Map.delete(metadata, :context)) =~ "s3cr3t"
      assert metadata.system_call? == false
    end

    test "spans fire with audit? off and write no model_calls rows", %{id: id, ref: ref} do
      MockProvider.script(completion("hi"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :model_call, :stop], ^ref, _measurements, _metadata}
      assert Agentix.Persistence.model_calls(id) == []
    end
  end

  describe "usage mapping" do
    test "accepts string keys, rejects non-integer and negative values" do
      assert %{input_tokens: 7, output_tokens: nil} =
               Telemetry.usage_measurements(%{"input_tokens" => 7, "output_tokens" => "bad"})

      assert %{input_tokens: nil} = Telemetry.usage_measurements(%{input_tokens: -5})
      assert %{input_tokens: nil, cached_tokens: nil} = Telemetry.usage_measurements(nil)
    end
  end
end
