defmodule Agentix.CompactionFlowTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Compaction.Summarize
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Event
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp msg_content(message), do: %{"message" => Jason.decode!(Codec.encode!(message))}

  defp seed_turn(id, user_text, assistant_text) do
    {:ok, _} = Persistence.append_event(id, user_event(id, user_text))
    {:ok, _} = Persistence.append_event(id, assistant_event(id, assistant_text))
  end

  defp user_event(id, text),
    do: Event.new(:user_msg, msg_content(Context.user(text)), conversation_id: id)

  defp assistant_event(id, text) do
    message = %Message{role: :assistant, content: [ContentPart.text(text)]}
    Event.new(:assistant_msg, msg_content(message), conversation_id: id)
  end

  defp put_summary(id, to_seq, text) do
    message = %Message{role: :system, content: [ContentPart.text(text)]}

    Persistence.put_summary(id, %{
      from_seq: 1,
      to_seq: to_seq,
      content: msg_content(message),
      version: "sum-v1"
    })
  end

  defp request_text do
    %{context: %Context{messages: messages}} = List.last(MockProvider.requests())

    messages
    |> Enum.flat_map(fn %Message{content: parts} -> Enum.map(parts, &(&1.text || "")) end)
    |> Enum.join("\n")
  end

  defp wait_for_summary(id, tries \\ 100) do
    case Persistence.latest_summary(id) do
      nil when tries > 0 -> Process.sleep(10) && wait_for_summary(id, tries - 1)
      summary -> summary
    end
  end

  describe "Summarize.run/2 — prefix-ward cumulative summary row" do
    test "collapses the oldest turns into a summary, leaving the recent tail", %{id: id} do
      seed_turn(id, "alpha", "resp1")
      seed_turn(id, "bravo", "resp2")
      seed_turn(id, "charlie", "resp3")
      MockProvider.script(completion("SUMMARY-OF-EARLIER"))

      assert :ok = Summarize.run(id, Config.new(model: "mock:test"))

      summary = Persistence.latest_summary(id)
      # 3 turns, keep the last 2 verbatim => collapse turn 1 (seq 1–2).
      assert summary[:to_seq] == 2
      assert summary[:from_seq] == 1
      message = Codec.decode_message(summary[:content]["message"])
      assert Enum.map_join(message.content, "", & &1.text) == "SUMMARY-OF-EARLIER"
    end
  end

  describe "assembly reads latest summary + verbatim tail" do
    test "the summary replaces the summarized span; only later events are verbatim", %{id: id} do
      seed_turn(id, "alpha-q", "alpha-a")
      seed_turn(id, "bravo-q", "bravo-a")
      put_summary(id, 2, "PRIOR-SUMMARY")

      MockProvider.script(completion("ok"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(id, working_budget: 30_000))
      :ok = Conversation.send_message(id, "new-question", Scope.new())
      assert_receive {:turn_completed, _ref}

      text = request_text()
      assert text =~ "PRIOR-SUMMARY"
      assert text =~ "bravo-q"
      assert text =~ "new-question"
      # The summarized first turn is gone from the rendered context.
      refute text =~ "alpha-q"
      refute text =~ "alpha-a"
    end
  end

  describe "over-budget turn triggers async summarization, next assembly reads it" do
    test "summary is written off the critical path and picked up next turn", %{id: id} do
      seed_turn(id, "alpha-" <> pad(), "resp1-" <> pad())
      seed_turn(id, "bravo-" <> pad(), "resp2-" <> pad())

      # Tiny budget: the 3rd turn pushes the rendered context over, triggering
      # prefix-ward summarization between turns.
      MockProvider.script([completion("resp3"), completion("SUMMARY3"), completion("resp4")])

      {:ok, _pid} =
        Conversation.ensure_started(id,
          config: config(id, working_budget: 20, injection_reserve: 1)
        )

      :ok = Conversation.send_message(id, "charlie-" <> pad(), Scope.new())
      assert_receive {:turn_completed, _ref}

      summary = wait_for_summary(id)
      assert summary[:to_seq] == 2

      :ok = Conversation.send_message(id, "delta", Scope.new())
      assert_receive {:turn_completed, _ref}

      text = request_text()
      assert text =~ "SUMMARY3"
      assert text =~ "bravo-"
      refute text =~ "alpha-"
    end
  end

  defp config(_id, opts), do: Config.new(Keyword.merge([model: "mock:test"], opts))
  defp pad, do: String.duplicate("x", 48)
end
