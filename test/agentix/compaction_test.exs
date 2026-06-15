defmodule Agentix.CompactionTest do
  use ExUnit.Case, async: true

  alias Agentix.Compaction.Budget
  alias Agentix.Compaction.SlidingWindow
  alias Agentix.Compaction.State
  alias Agentix.Compaction.ToolResult
  alias Agentix.Conversation.Config
  alias Agentix.Tokenizer
  alias Agentix.Tokenizer.Heuristic
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  defp state(config), do: %State{config: config}
  defp user(text), do: %Message{role: :user, content: [ContentPart.text(text)]}
  defp assistant(text), do: %Message{role: :assistant, content: [ContentPart.text(text)]}

  defp calls(text, tool_calls),
    do: %Message{role: :assistant, content: [ContentPart.text(text)], tool_calls: tool_calls}

  defp result(id, text),
    do: %Message{role: :tool, tool_call_id: id, content: [ContentPart.text(text)]}

  defp tc(id, name), do: ToolCall.new(id, name, "{}")

  defp result_text(messages, id) do
    messages
    |> Enum.find(&match?(%Message{role: :tool, tool_call_id: ^id}, &1))
    |> then(fn %Message{content: [%{text: text}]} -> text end)
  end

  describe "Tokenizer" do
    test "the heuristic is char/4 with a +1 floor, and dispatches through count/1" do
      assert Heuristic.count("") == 1
      assert Heuristic.count("abcdefgh") == 3
      assert Tokenizer.count("abcdefgh") == 3
    end

    test "count_context sums text parts across messages" do
      context = Context.new([user("abcd"), assistant("efgh")])
      # div(4,4)+1 == 2, twice
      assert Tokenizer.count_context(context) == 4
    end
  end

  describe "Budget — opaque value with a per-tier caps slot (forward-compat)" do
    test "cap/2 falls back to total; fits?/2 checks the total" do
      budget = Budget.new(100, %{tool_results: 50})

      assert Budget.cap(budget, :tool_results) == 50
      assert Budget.cap(budget, :dialogue) == 100
      assert Budget.fits?(budget, 100)
      refute Budget.fits?(budget, 101)
    end

    test "a per-tier sub-limit does not change the reduce/3 signature" do
      budget = Budget.new(100, %{tool_results: 50})
      context = Context.new([user("hi")])

      assert {%Context{}, %State{}} =
               ToolResult.reduce(context, budget, state(Config.new(model: "m")))
    end
  end

  describe "ToolResult — stub-not-drop, pairing intact" do
    test "age mode: results older than the window are stubbed, recent ones kept" do
      config = Config.new(model: "m", tool_retention: %{mode: :age, value: 1, never_evict: false})

      context =
        Context.new([
          user("q1"),
          calls("", [tc("c1", "search")]),
          result("c1", "OLD"),
          user("q2"),
          calls("", [tc("c2", "search")]),
          result("c2", "NEW")
        ])

      {%Context{messages: out}, _state} =
        ToolResult.reduce(context, Budget.new(9_999), state(config))

      # Every message survives (the call/result pairing is never broken)...
      assert length(out) == 6
      # ...the older result is stubbed, the recent one is verbatim.
      assert result_text(out, "c1") == "[result expired]"
      assert result_text(out, "c2") == "NEW"
    end

    test "count mode: only the last N results of that tool are kept" do
      config = Config.new(model: "m", tool_retention: %{mode: :count, value: 1, never_evict: false})

      context =
        Context.new([
          user("q1"),
          calls("", [tc("c1", "search")]),
          result("c1", "FIRST"),
          user("q2"),
          calls("", [tc("c2", "search")]),
          result("c2", "SECOND")
        ])

      {%Context{messages: out}, _state} =
        ToolResult.reduce(context, Budget.new(9_999), state(config))

      assert result_text(out, "c1") == "[result expired]"
      assert result_text(out, "c2") == "SECOND"
    end

    test "never_evict keeps results regardless of age" do
      config = Config.new(model: "m", tool_retention: %{mode: :age, value: 1, never_evict: true})

      context =
        Context.new([
          user("q1"),
          calls("", [tc("c1", "search")]),
          result("c1", "KEEP"),
          user("q2"),
          assistant("done")
        ])

      {%Context{messages: out}, _state} =
        ToolResult.reduce(context, Budget.new(9_999), state(config))

      assert result_text(out, "c1") == "KEEP"
    end
  end

  describe "SlidingWindow — keep the prefix and the last W turns" do
    test "drops whole old turns (never orphaning a tool pair)" do
      config = Config.new(model: "m", compaction_window: 2)
      system = %Message{role: :system, content: [ContentPart.text("sys")]}

      context =
        Context.new([
          system,
          user("t1"),
          assistant("a1"),
          user("t2"),
          assistant("a2"),
          user("t3"),
          assistant("a3")
        ])

      {%Context{messages: out}, _state} =
        SlidingWindow.reduce(context, Budget.new(9_999), state(config))

      assert out == [system, user("t2"), assistant("a2"), user("t3"), assistant("a3")]
    end
  end
end
