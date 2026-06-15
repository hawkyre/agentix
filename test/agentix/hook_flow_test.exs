defmodule Agentix.HookFlowTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Hook
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(opts), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  defp last_user_texts do
    %{context: context} = List.last(MockProvider.requests())

    context.messages
    |> Enum.reverse()
    |> Enum.find(&match?(%Message{role: :user}, &1))
    |> Map.fetch!(:content)
    |> Enum.map(& &1.text)
  end

  defp assistant_events(id) do
    id |> Persistence.stream_events() |> Enum.filter(&(&1.type == :assistant_msg))
  end

  describe "pre-hook injection placement (D7 — tail, adjacent to the user message)" do
    test "a parallel batch [X, Y] appends both parts after the user message, in order", %{id: id} do
      x = Hook.pre(:x, fn _t -> {:cont, [ContentPart.text("[X]")]} end, mode: :parallel)
      y = Hook.pre(:y, fn _t -> {:cont, [ContentPart.text("[Y]")]} end, mode: :parallel)

      MockProvider.script(completion("ok"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(hooks: [x, y]))
      :ok = Conversation.send_message(id, "hi", Scope.new())

      assert_receive {:turn_completed, _ref}
      assert last_user_texts() == ["hi", "[X]", "[Y]"]
    end
  end

  describe "pre-hook halt" do
    test "a halting pre-hook ends the turn with no model call and no assistant message", %{id: id} do
      block = Hook.pre(:guard, fn _t -> {:halt, :blocked} end)

      MockProvider.script(completion("never reached"))
      {:ok, pid} = Conversation.ensure_started(id, config: config(hooks: [block]))
      :ok = Conversation.send_message(id, "hi", Scope.new())

      assert_receive {:turn_started, _ref}
      assert_receive {:turn_halted, _ref, :blocked}
      assert_receive {:state_changed, :idle}
      refute_received {:message_completed, _, _}
      refute_received {:turn_completed, _}

      assert assistant_events(id) == []
      assert MockProvider.requests() == []
      assert Process.alive?(pid)
    end
  end

  describe "post-hook" do
    test "runs after :message_completed and sees the finalized assistant message", %{id: id} do
      test = self()

      record =
        Hook.post(:record, fn t ->
          send(test, {:post_ran, t.assistant_message})
          {:cont, t}
        end)

      MockProvider.script(completion("hi there"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(hooks: [record]))
      :ok = Conversation.send_message(id, "hi", Scope.new())

      assert_receive {:message_completed, _ref, %Message{}}
      assert_receive {:post_ran, %Message{role: :assistant} = message}
      assert_receive {:turn_completed, _ref}

      assert Enum.map_join(message.content, "", & &1.text) == "hi there"
    end
  end

  describe "stream-transformer seam" do
    test "the registered transformer is invoked once per chunk", %{id: id} do
      test = self()

      transformer = fn chunk ->
        send(test, {:seen, chunk})
        chunk
      end

      # thinking + text => two chunks.
      MockProvider.script(completion("hello", thinking: "hmm"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(stream_transformer: transformer))
      :ok = Conversation.send_message(id, "hi", Scope.new())

      assert_receive {:turn_completed, _ref}
      assert_receive {:seen, _chunk_1}
      assert_receive {:seen, _chunk_2}
      refute_received {:seen, _chunk_3}
    end
  end
end
