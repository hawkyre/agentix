defmodule Agentix.ConversationTest.SlowProvider do
  @moduledoc false
  # Yields one text chunk then blocks, so a test can deterministically cancel
  # mid-stream. The cancel closure pings the test process so we can assert it ran.
  @behaviour Agentix.Provider

  alias ReqLLM.Message
  alias ReqLLM.StreamChunk

  @impl true
  def stream(_model, _context, _opts) do
    test = Application.get_env(:agentix, :cancel_test_pid)

    chunks =
      Stream.resource(
        fn -> 0 end,
        fn
          0 -> {[StreamChunk.text("partial")], 1}
          1 -> {block_forever(), 2}
          2 -> {:halt, 2}
        end,
        fn _ -> :ok end
      )

    cancel = fn ->
      send(test, :cancel_closure_called)
      :ok
    end

    finalize = fn -> {%Message{role: :assistant, content: []}, %{}} end
    {:ok, %Agentix.Provider.Stream{chunks: chunks, cancel: cancel, finalize: finalize}}
  end

  defp block_forever do
    receive do
      :never -> []
    end
  end
end

defmodule Agentix.ConversationTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.ConversationTest.SlowProvider
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias ReqLLM.Message

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(opts \\ []), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  defp assistant_text(id) do
    id
    |> Persistence.stream_events()
    |> Enum.filter(&(&1.type == :assistant_msg))
    |> List.last()
    |> then(fn event -> Codec.decode_message(event.content["message"]) end)
    |> Map.fetch!(:content)
    |> Enum.map_join("", & &1.text)
  end

  describe "send_message/3 — the turn loop" do
    test "moves idle→preparing→streaming→idle and logs user + assistant", %{id: id} do
      MockProvider.script(completion("Hello there"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(system_prompt: "Be terse."))

      assert :ok = Conversation.send_message(id, "Hi", Scope.new())

      assert_receive {:turn_started, ref}
      assert_receive {:state_changed, :preparing}
      assert_receive {:state_changed, :streaming}
      assert_receive {:text_delta, ^ref, msg_id, "Hello there"}
      assert_receive {:message_completed, ^ref, %Message{role: :assistant} = message}
      assert_receive {:turn_completed, ^ref}
      assert_receive {:state_changed, :idle}

      # the live deltas and the finalized message share an id (renderer keys on it)
      assert message.metadata["id"] == msg_id

      events = Persistence.stream_events(id)
      assert [%{type: :user_msg}, %{type: :assistant_msg}] = Enum.map(events, & &1)
      assert assistant_text(id) == "Hello there"
    end

    test "the provider receives the assembled context (system + user)", %{id: id} do
      MockProvider.script(completion("ok"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(system_prompt: "Be terse."))

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:turn_completed, _ref}

      assert [%{context: context}] = MockProvider.requests()
      roles = context |> ReqLLM.Context.to_list() |> Enum.map(& &1.role)
      assert roles == [:system, :user]
    end

    test "thinking deltas are broadcast", %{id: id} do
      MockProvider.script(completion("answer", thinking: "let me think"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:thinking_delta, _ref, _msg_id, "let me think"}
      assert_receive {:text_delta, _ref, _msg_id, "answer"}
      assert_receive {:turn_completed, _ref}
    end
  end

  describe "cancellation" do
    setup do
      Application.put_env(:agentix, :provider, SlowProvider)
      Application.put_env(:agentix, :cancel_test_pid, self())
      on_exit(fn -> Application.delete_env(:agentix, :cancel_test_pid) end)
      :ok
    end

    test "cancel from streaming invokes the cancel closure and records a partial turn",
         %{id: id} do
      {:ok, _pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "Hi", Scope.new())

      # wait until the partial text has streamed (agent is now parked in streaming)
      assert_receive {:text_delta, _ref, _msg_id, "partial"}

      assert :ok = Conversation.cancel(id)

      assert_receive :cancel_closure_called
      assert_receive {:cancelled, _ref}
      assert_receive {:state_changed, :idle}

      assert assistant_text(id) == "partial [cancelled]"
    end

    test "a second send while streaming returns {:error, :busy}", %{id: id} do
      {:ok, _pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:text_delta, _ref, _msg_id, "partial"}

      assert {:error, :busy} = Conversation.send_message(id, "again", Scope.new())

      Conversation.cancel(id)
    end
  end

  describe "ensure_started — recovery" do
    test "a log ending in a dangling user_msg is re-run on revival", %{id: id} do
      # Seed a user message with no assistant reply (as if killed mid-stream), then
      # start the agent: it should re-run the turn (no side effects had happened).
      seed = ReqLLM.Context.user("recover me")
      content = %{"message" => Jason.decode!(Codec.encode!(seed))}
      {:ok, _seq} = Persistence.append_event(id, Agentix.Event.new(:user_msg, content))

      MockProvider.script(completion("recovered"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      assert_receive {:message_completed, _ref, %Message{}}
      assert_receive {:turn_completed, _ref}
      assert assistant_text(id) == "recovered"

      # The seeded user_msg must NOT be re-appended on rerun — exactly one of each.
      assert [%{type: :user_msg}, %{type: :assistant_msg}] = Persistence.stream_events(id)
    end

    test "send_message for an unknown conversation without config errors", %{id: id} do
      assert {:error, :unknown_conversation} =
               Conversation.send_message(id, "Hi", Scope.new())
    end
  end
end
