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
  alias Agentix.Tool
  alias ReqLLM.Context
  alias ReqLLM.Message

  @fast_retry %{max_attempts: 3, base_ms: 1, max_ms: 5}

  @telemetry_events [
    [:agentix, :model_call, :start],
    [:agentix, :model_call, :stop],
    [:agentix, :model_call, :exception],
    [:agentix, :tool, :start],
    [:agentix, :tool, :stop],
    [:agentix, :tool, :exception]
  ]

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))

    handler_ref = :telemetry_test.attach_event_handlers(self(), @telemetry_events)
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

  describe "[:agentix, :tool] spans" do
    test "a :server tool emits start and stop with its result", %{id: id, ref: ref} do
      echo =
        Tool.new(name: "echo", executor: :server, callback: fn args, _t -> {:ok, args["q"]} end)

      MockProvider.script([
        completion("", tool_calls: [{"echo", %{"q" => "x"}}]),
        completion("done")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config(tools: [echo]))

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :tool, :start], ^ref, %{system_time: _, monotonic_time: _},
                      metadata}

      assert %{conversation_id: ^id, name: "echo", executor: :server, args: %{"q" => "x"}} =
               metadata

      refute Map.has_key?(metadata, :scope)
      tool_call_id = metadata.tool_call_id

      assert_receive {[:agentix, :tool, :stop], ^ref, measurements,
                      %{tool_call_id: ^tool_call_id, status: :ok, result: %{ok: true, result: "x"}}}

      assert is_integer(measurements.duration)
      assert is_integer(measurements.latency_ms) and measurements.latency_ms >= 0
      assert is_integer(measurements.monotonic_time)
    end

    test "a :human tool's span covers the suspension", %{id: id, ref: ref} do
      ask = Tool.new(name: "ask", executor: :human)

      MockProvider.script([
        completion("", tool_calls: [{"ask", %{"q" => "name?"}}]),
        completion("thanks")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config(tools: [ask]))

      :ok = Conversation.send_message(id, "Hi", Scope.new())

      assert_receive {[:agentix, :tool, :start], ^ref, _measurements,
                      %{name: "ask", executor: :human, tool_call_id: tool_call_id}}

      wait_ms = 30
      Process.sleep(wait_ms)
      assert :ok = Agentix.resolve(id, tool_call_id, "Bob")
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :tool, :stop], ^ref, measurements,
                      %{tool_call_id: ^tool_call_id, status: :ok}}

      assert measurements.latency_ms >= wait_ms
    end

    test "a killed :server tool task emits :exception, not :stop", %{id: id, ref: ref} do
      dying = Tool.new(name: "dying", executor: :server, callback: fn _a, _t -> exit(:boom) end)
      MockProvider.script([completion("", tool_calls: [{"dying", %{}}]), completion("recovered")])
      {:ok, _pid} = Conversation.ensure_started(id, config: config(tools: [dying]))

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :tool, :start], ^ref, _measurements,
                      %{name: "dying", tool_call_id: tool_call_id}}

      assert_receive {[:agentix, :tool, :exception], ^ref, %{duration: _, monotonic_time: _},
                      %{tool_call_id: ^tool_call_id, kind: :exit, reason: :boom, stacktrace: []}}

      refute_receive {[:agentix, :tool, :stop], ^ref, %{}, %{tool_call_id: ^tool_call_id}}, 30
    end

    test "an unknown tool closes its span with an error status", %{id: id, ref: ref} do
      MockProvider.script([completion("", tool_calls: [{"nope", %{}}]), completion("ok")])
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :tool, :start], ^ref, _measurements,
                      %{name: "nope", executor: nil}}

      assert_receive {[:agentix, :tool, :stop], ^ref, _stop_measurements,
                      %{name: "nope", status: :error, result: %{ok: false}}}
    end
  end

  describe "tenant_key" do
    test "stamps model_call and tool metadata and is write-once", %{id: id, ref: ref} do
      echo = Tool.new(name: "echo", executor: :server, callback: fn _a, _t -> {:ok, 1} end)
      MockProvider.script([completion("", tool_calls: [{"echo", %{}}]), completion("done")])

      {:ok, _pid} =
        Conversation.ensure_started(id, config: config(tools: [echo]), tenant_key: "acme")

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}

      assert_receive {[:agentix, :model_call, :start], ^ref, _m1, %{tenant_key: "acme"}}
      assert_receive {[:agentix, :tool, :start], ^ref, _m2, %{tenant_key: "acme"}}
      assert Agentix.Persistence.get_conversation(id).tenant_key == "acme"

      # Write-once: same key is a no-op, a different key conflicts — running or revived.
      assert {:ok, _pid} = Conversation.ensure_started(id, tenant_key: "acme")
      assert {:error, :tenant_key_conflict} = Conversation.ensure_started(id, tenant_key: "other")
      :ok = Conversation.stop(id)
      assert {:error, :tenant_key_conflict} = Conversation.ensure_started(id, tenant_key: "other")
    end

    test "untenanted conversations stamp nil", %{id: id, ref: ref} do
      MockProvider.script(completion("hi"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _turn_ref}
      assert_receive {[:agentix, :model_call, :start], ^ref, _measurements, %{tenant_key: nil}}
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
