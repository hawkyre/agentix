defmodule Agentix.HookTest do
  use ExUnit.Case, async: true

  alias Agentix.Hook
  alias Agentix.Scope
  alias Agentix.Turn
  alias ReqLLM.Message.ContentPart

  describe "new/1 and the pre/post helpers" do
    test "builds pre (sequential default) and post hooks" do
      run = fn t -> {:cont, t} end

      assert %Hook{phase: :pre, mode: :sequential, durable?: false} = Hook.pre(:a, run)
      assert %Hook{phase: :pre, mode: :parallel} = Hook.pre(:a, run, mode: :parallel)
      assert %Hook{phase: :post, durable?: true} = Hook.post(:a, run, durable?: true)
    end

    test "rejects an invalid phase/mode, a non-1-arity run, and a parallel post hook" do
      run = fn t -> {:cont, t} end

      assert_raise ArgumentError, ~r/invalid hook phase/, fn ->
        Hook.new(name: :a, phase: :bogus, run: run)
      end

      assert_raise ArgumentError, ~r/invalid hook mode/, fn ->
        Hook.new(name: :a, phase: :pre, run: run, mode: :bogus)
      end

      assert_raise ArgumentError, ~r/1-arity :run/, fn ->
        Hook.new(name: :a, phase: :pre, run: fn _x, _y -> :ok end)
      end

      assert_raise ArgumentError, ~r/:parallel is only legal for a :pre hook/, fn ->
        Hook.new(name: :a, phase: :post, run: run, mode: :parallel)
      end
    end
  end

  describe "inject/2" do
    test "appends a part or list of parts to the turn's injections, in order" do
      turn = Turn.new(scope: Scope.system())
      one = ContentPart.text("one")
      two = ContentPart.text("two")

      assert %Turn{injections: [^one]} = turn = Hook.inject(turn, one)
      assert %Turn{injections: [^one, ^two]} = Hook.inject(turn, [two])
    end
  end

  describe "transform_chunk/2" do
    test "is the identity for a nil transformer and applies a function otherwise" do
      assert Hook.transform_chunk(:chunk, nil) == :chunk
      assert Hook.transform_chunk(2, &(&1 * 10)) == 20
    end
  end
end
