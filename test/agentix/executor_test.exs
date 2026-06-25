defmodule Agentix.ExecutorTest do
  use ExUnit.Case, async: true

  alias Agentix.Executor

  doctest Executor

  test "all/0 is the closed executor set" do
    assert Executor.all() == [:server, :human, :client, :provider]
  end

  test "valid?/1 reflects membership" do
    for executor <- Executor.all(), do: assert(Executor.valid?(executor))
    refute Executor.valid?(:sub_agent)
  end

  test "validate!/1 returns the executor when valid" do
    assert Executor.validate!(:human) == :human
  end

  test "validate!/1 raises on an invalid executor" do
    assert_raise ArgumentError, ~r/invalid executor :sub_agent/, fn ->
      Executor.validate!(:sub_agent)
    end
  end
end
