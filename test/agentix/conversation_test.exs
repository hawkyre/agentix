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
  alias Agentix.Tool
  alias ReqLLM.Message

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(opts \\ []), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  defp request_text do
    %{context: context} = List.last(MockProvider.requests())

    context
    |> ReqLLM.Context.to_list()
    |> Enum.map_join("\n", fn message -> Enum.map_join(message.content, "", &(&1.text || "")) end)
  end

  defp assistant_text(id),
    do: id |> last_assistant() |> Map.fetch!(:content) |> Enum.map_join("", & &1.text)

  defp assistant_status(id),
    do: id |> last_assistant() |> Map.fetch!(:metadata) |> Map.get("status")

  defp last_assistant(id) do
    id
    |> Persistence.stream_events()
    |> Enum.filter(&(&1.type == :assistant_msg))
    |> List.last()
    |> then(fn event -> Codec.decode_message(event.content["message"]) end)
  end

  describe "send_message/3 — the turn loop" do
    test "moves idle→preparing→streaming→idle and logs user + assistant", %{id: id} do
      MockProvider.script(completion("Hello there"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(system_prompt: "Be terse."))

      assert :ok = Conversation.send_message(id, "Hi", Scope.new())

      assert_receive {:turn_started, ref}
      assert_receive {:state_changed, :preparing}
      assert_receive {:state_changed, :streaming}
      assert_receive {:text_delta, ^ref, msg_id, "Hello there", _seq}
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
      assert_receive {:thinking_delta, _ref, _msg_id, "let me think", _seq}
      assert_receive {:text_delta, _ref, _msg_id, "answer", _seq}
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
      assert_receive {:text_delta, _ref, _msg_id, "partial", _seq}

      assert :ok = Conversation.cancel(id)

      assert_receive :cancel_closure_called
      assert_receive {:cancelled, _ref}
      assert_receive {:state_changed, :idle}

      # The partial text is stored clean; the truncation reason lives in metadata.
      assert assistant_text(id) == "partial"
      assert assistant_status(id) == "cancelled"
    end

    test "a second send while streaming returns {:error, :busy}", %{id: id} do
      {:ok, _pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:text_delta, _ref, _msg_id, "partial", _seq}

      assert {:error, :busy} = Conversation.send_message(id, "again", Scope.new())

      Conversation.cancel(id)
    end

    test "the next turn's context re-shows a cancelled turn's truncation marker", %{id: id} do
      {:ok, _pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "Hi", Scope.new())
      assert_receive {:text_delta, _ref, _msg_id, "partial", _seq}
      assert :ok = Conversation.cancel(id)
      assert_receive {:cancelled, _ref}

      # The partial is stored clean; the model-context path re-applies the marker so the
      # next turn's request shows the prior turn was cut.
      install_mock_provider()
      MockProvider.script(completion("ok"))
      :ok = Conversation.send_message(id, "continue", Scope.new())
      assert_receive {:turn_completed, _ref}

      assert request_text() =~ "partial [turn cancelled]"

      # The truncation reason rides the wire as text only — the internal `status`/`id`
      # metadata is stripped at the model boundary, never serialized to the provider.
      %{context: context} = List.last(MockProvider.requests())

      for message <- ReqLLM.Context.to_list(context) do
        refute Map.has_key?(message.metadata || %{}, "status")
        refute Map.has_key?(message.metadata || %{}, "id")
      end
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

    test "the audit model_call counter resumes after a kill/revive (no overwrite)", %{id: id} do
      Application.put_env(:agentix, :audit, true)
      on_exit(fn -> Application.delete_env(:agentix, :audit) end)
      MockProvider.script([completion("one"), completion("two")])

      {:ok, pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "first", Scope.new())
      assert_receive {:turn_completed, _r1}

      # Kill the agent; the owner-held model_calls table survives it, and the
      # transient supervisor revives a fresh process that rehydrates from the log.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      wait_until(fn ->
        match?([{new_pid, _}] when new_pid != pid, Registry.lookup(Agentix.Registry, id))
      end)

      :ok = Conversation.send_message(id, "second", Scope.new())
      assert_receive {:turn_completed, _r2}

      # Without resuming the counter the second turn would reuse turn_ref 1 and clobber
      # the first audit row; it must continue at 2.
      assert [1, 2] == id |> Persistence.model_calls() |> Enum.map(& &1.turn_ref)
    end

    test "a dangling tool_call (auto-server killed mid-run) is reconciled on revival",
         %{id: id} do
      # Seed a log with a :tool_call that has no paired :tool_result — as if an auto-server
      # tool was running when the agent was killed (such calls aren't persisted as pending).
      {:ok, _} =
        Persistence.append_event(
          id,
          Agentix.Event.new(:tool_call, %{
            "tool_call_id" => "call_x",
            "name" => "weather",
            "args" => %{}
          })
        )

      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      # Revival pairs the dangling call with an interrupted-error result (it does NOT
      # re-execute the tool) so the log is valid for the next turn.
      result =
        id
        |> Persistence.stream_events()
        |> Enum.find(&(&1.type == :tool_result and &1.content["tool_call_id"] == "call_x"))

      assert result
      assert result.content["result"].ok == false
      assert result.content["result"].error =~ "interrupted"
    end

    test "a conversation killed while suspended on a human tool revives and resolves",
         %{id: id} do
      ask = Tool.new(name: "ask", executor: :human)

      MockProvider.script([
        completion("", tool_calls: [{"ask", %{"prompt" => "name?"}}]),
        completion("Hi Bob")
      ])

      {:ok, pid} = Conversation.ensure_started(id, config: config(tools: [ask]))
      :ok = Conversation.send_message(id, "greet", Scope.new())
      assert_receive {:suspended, tool_call_id, :human, _prompt}

      # Kill mid-suspension. The durable tool-call record + fsm_state survive; the
      # transient supervisor revives a fresh process that must come back in
      # `awaiting_input` with the pending call rehydrated (not `:idle`).
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      wait_until(fn ->
        match?([{new_pid, _}] when new_pid != pid, Registry.lookup(Agentix.Registry, id))
      end)

      # The late resolution reaches the revived agent (not `{:error, :stale}`) and the
      # turn runs to completion — the durable-suspension guarantee.
      assert :ok = Agentix.resolve(id, tool_call_id, "Bob")
      assert_receive {:turn_completed, _ref}
      assert assistant_text(id) == "Hi Bob"
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if !fun.() do
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
