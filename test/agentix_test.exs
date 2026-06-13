defmodule AgentixTest do
  use ExUnit.Case, async: true

  doctest Agentix

  test "the supervision tree is running" do
    assert Process.whereis(Agentix.Supervisor)
    assert Process.whereis(Agentix.Registry)
    assert Process.whereis(Agentix.ConversationSupervisor)
  end
end
