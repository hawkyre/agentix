defmodule Agentix.Hook.PipelineTest do
  use ExUnit.Case, async: true

  alias Agentix.Hook
  alias Agentix.Hook.OverflowError
  alias Agentix.Hook.Pipeline
  alias Agentix.Scope
  alias Agentix.Turn
  alias ReqLLM.Message.ContentPart

  @reserve 10_000

  defp turn, do: Turn.new(scope: Scope.system())

  describe "run_pre/3 — sequential" do
    test "halts at B; A's injection is present at the halt point and C never runs" do
      test = self()
      part_a = ContentPart.text("from A")

      a = Hook.pre(:a, fn t -> {:cont, Hook.inject(t, part_a)} end)

      b =
        Hook.pre(:b, fn t ->
          send(test, {:b_saw, t.injections})
          {:halt, :blocked}
        end)

      c =
        Hook.pre(:c, fn t ->
          send(test, :c_ran)
          {:cont, t}
        end)

      assert {:halt, :blocked} = Pipeline.run_pre(turn(), [a, b, c], @reserve)

      # B saw A's injected part (A ran and injected before the halt)...
      assert_received {:b_saw, [^part_a]}
      # ...and C was short-circuited.
      refute_received :c_ran
    end

    test "without a halt, sequential injections accumulate in declaration order" do
      part_a = ContentPart.text("A")
      part_b = ContentPart.text("B")

      a = Hook.pre(:a, fn t -> {:cont, Hook.inject(t, part_a)} end)
      b = Hook.pre(:b, fn t -> {:cont, Hook.inject(t, part_b)} end)

      assert {:cont, %Turn{injections: [^part_a, ^part_b]}} =
               Pipeline.run_pre(turn(), [a, b], @reserve)
    end

    test "a malformed sequential return raises a clear contract error" do
      bad = Hook.pre(:bad, fn _t -> :nope end)

      assert_raise ArgumentError, ~r/sequential pre-hook :bad must return/, fn ->
        Pipeline.run_pre(turn(), [bad], @reserve)
      end
    end
  end

  describe "run_pre/3 — parallel batch" do
    test "appends each batch's parts at the tail in declaration order (X before Y)" do
      part_x = ContentPart.text("X")
      part_y = ContentPart.text("Y")

      x = Hook.pre(:x, fn _t -> {:cont, [part_x]} end, mode: :parallel)
      y = Hook.pre(:y, fn _t -> {:cont, [part_y]} end, mode: :parallel)

      assert {:cont, %Turn{injections: [^part_x, ^part_y]}} =
               Pipeline.run_pre(turn(), [x, y], @reserve)
    end

    test "a crashing parallel injector is skipped, not fatal" do
      part_y = ContentPart.text("Y")

      x = Hook.pre(:x, fn _t -> raise "boom" end, mode: :parallel)
      y = Hook.pre(:y, fn _t -> {:cont, [part_y]} end, mode: :parallel)

      assert {:cont, %Turn{injections: [^part_y]}} = Pipeline.run_pre(turn(), [x, y], @reserve)
    end
  end

  describe "run_pre/3 — injection_reserve (D7)" do
    test "an over-reserve injection raises OverflowError naming the hook" do
      big =
        Hook.pre(:big, fn t ->
          {:cont, Hook.inject(t, ContentPart.text(String.duplicate("x", 100)))}
        end)

      error =
        assert_raise OverflowError, ~r/:big/, fn ->
          Pipeline.run_pre(turn(), [big], 5)
        end

      assert error.hook == :big
      assert error.reserve == 5
      assert error.size > 5
    end
  end

  describe "run_post/2" do
    test "folds the turn and short-circuits on :halt" do
      test = self()

      p1 =
        Hook.post(:p1, fn t ->
          send(test, :p1_ran)
          {:cont, t}
        end)

      p2 = Hook.post(:p2, fn _t -> {:halt, :stop} end)

      p3 =
        Hook.post(:p3, fn t ->
          send(test, :p3_ran)
          {:cont, t}
        end)

      assert {:halt, :stop} = Pipeline.run_post(turn(), [p1, p2, p3])
      assert_received :p1_ran
      refute_received :p3_ran
    end
  end
end
