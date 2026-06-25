defmodule Agentix.AgentRetryTest.FlakyChunkProvider do
  @moduledoc false
  # Emits one text chunk, then raises during enumeration — a mid-stream failure. The
  # retry layer must NOT re-issue this (a token already streamed); the turn fails.
  @behaviour Agentix.Provider

  alias ReqLLM.Message
  alias ReqLLM.StreamChunk

  @impl true
  def stream(_model, _context, _opts) do
    chunks =
      Stream.resource(
        fn -> 0 end,
        fn
          0 -> {[StreamChunk.text("partial")], 1}
          1 -> raise "mid-stream boom"
        end,
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

defmodule Agentix.AgentRetryTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.AgentRetryTest.FlakyChunkProvider
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope
  alias Agentix.Test.MockProvider

  # Near-instant backoff so the suite stays fast while still exercising the loop.
  @fast_retry %{max_attempts: 3, base_ms: 1, max_ms: 5}

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))

    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:agentix, :turn, :retry], &__MODULE__.forward_retry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, id: id}
  end

  @doc false
  # Telemetry handler — a named capture (not an anonymous fn) so telemetry doesn't warn.
  def forward_retry(_event, measurements, metadata, test_pid),
    do: send(test_pid, {:retry_telemetry, measurements, metadata})

  defp config(opts), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  test "retries a transient 5xx then completes the turn", %{id: id} do
    MockProvider.script([error(503), error(503), completion("recovered")])
    {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: @fast_retry))

    :ok = Conversation.send_message(id, "Hi", Scope.new())

    # Two retries (attempts 1 and 2 failed; attempt 3 succeeded), then a normal completion.
    assert_receive {:retry_telemetry, %{attempt: 1, delay_ms: d1},
                    %{conversation_id: ^id, turn_ref: _}}

    assert is_integer(d1)
    assert_receive {:retry_telemetry, %{attempt: 2}, %{conversation_id: ^id}}
    assert_receive {:message_completed, _ref, _message}
    assert_receive {:turn_completed, _ref}

    # No third retry: max_attempts is 3, so attempt 3 is the last and is not preceded by a retry event.
    refute_receive {:retry_telemetry, %{attempt: 3}, _}, 30
    assert assistant_text(id) == "recovered"

    # The provider was hit exactly three times (two failures + the success).
    assert length(MockProvider.requests()) == 3
  end

  test "a non-retryable 4xx fails the turn immediately with no retries", %{id: id} do
    MockProvider.script(error(401, reason: "unauthorized"))
    {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: @fast_retry))

    :ok = Conversation.send_message(id, "Hi", Scope.new())

    assert_receive {:cancelled, _ref}
    assert_receive {:state_changed, :idle}
    refute_receive {:retry_telemetry, _, _}, 30
    assert length(MockProvider.requests()) == 1
  end

  test "retry: false does a single attempt even on a retryable error", %{id: id} do
    MockProvider.script([error(503), completion("unreached")])
    {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: false))

    :ok = Conversation.send_message(id, "Hi", Scope.new())

    assert_receive {:cancelled, _ref}
    refute_receive {:retry_telemetry, _, _}, 30
    assert length(MockProvider.requests()) == 1
  end

  test "honors a custom max_attempts (2 attempts → 1 retry)", %{id: id} do
    MockProvider.script([error(503), error(503), completion("unreached")])

    {:ok, _pid} =
      Conversation.ensure_started(id,
        config: config(retry: %{max_attempts: 2, base_ms: 1, max_ms: 5})
      )

    :ok = Conversation.send_message(id, "Hi", Scope.new())

    assert_receive {:retry_telemetry, %{attempt: 1}, _}
    # Only one retry: attempt 2 is the last and still fails, so the turn fails.
    refute_receive {:retry_telemetry, %{attempt: 2}, _}, 30
    assert_receive {:cancelled, _ref}
    assert length(MockProvider.requests()) == 2
  end

  test "a mid-stream failure is NOT retried (tokens already streamed)", %{id: id} do
    Application.put_env(:agentix, :provider, FlakyChunkProvider)
    on_exit(fn -> Application.put_env(:agentix, :provider, MockProvider) end)

    {:ok, _pid} = Conversation.ensure_started(id, config: config(retry: @fast_retry))
    :ok = Conversation.send_message(id, "Hi", Scope.new())

    # The first token forwards, then the stream crashes — the turn fails, with no retry.
    assert_receive {:text_delta, _ref, _msg_id, "partial", _seq}
    assert_receive {:cancelled, _ref}
    refute_receive {:retry_telemetry, _, _}, 30
  end

  # The assistant's final text from the durable log.
  defp assistant_text(id) do
    id
    |> Agentix.Persistence.stream_events()
    |> Enum.filter(&(&1.type == :assistant_msg))
    |> List.last()
    |> case do
      nil -> nil
      event -> event.content["message"] |> Agentix.Codec.decode_message() |> text_of()
    end
  end

  defp text_of(%ReqLLM.Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end
end
