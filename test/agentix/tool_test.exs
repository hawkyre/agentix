defmodule Agentix.ToolTest do
  use ExUnit.Case, async: true

  alias Agentix.Scope
  alias Agentix.Tool
  alias Agentix.Turn

  describe "Tool.new/1 — gate matrix" do
    test "builds a valid tool of each executor" do
      assert %Tool{executor: :server} =
               Tool.new(name: "t", executor: :server, callback: fn _a, _t -> {:ok, 1} end)

      assert %Tool{executor: :human} = Tool.new(name: "t", executor: :human)
      assert %Tool{executor: :client} = Tool.new(name: "t", executor: :client)
      assert %Tool{executor: :provider} = Tool.new(name: "t", executor: :provider)
    end

    test "allows the gate on :server and :client" do
      assert %Tool{approval: :requires_approval} =
               Tool.new(
                 name: "t",
                 executor: :server,
                 approval: :requires_approval,
                 callback: fn _a, _t -> {:ok, 1} end
               )

      assert %Tool{approval: :requires_approval} =
               Tool.new(name: "t", executor: :client, approval: :requires_approval)
    end

    test "rejects a gated :human (circular)" do
      assert_raise ArgumentError, ~r/illegal for executor :human/, fn ->
        Tool.new(name: "t", executor: :human, approval: :requires_approval)
      end
    end

    test "rejects a gated :provider (no pre-exec suspend point)" do
      assert_raise ArgumentError, ~r/illegal for executor :provider/, fn ->
        Tool.new(name: "t", executor: :provider, approval: :requires_approval)
      end
    end

    test "rejects an unknown executor and a missing :server callback" do
      assert_raise ArgumentError, ~r/invalid executor/, fn ->
        Tool.new(name: "t", executor: :nonsense)
      end

      assert_raise ArgumentError, ~r/requires a 2-arity :callback/, fn ->
        Tool.new(name: "t", executor: :server)
      end
    end
  end

  describe "Tool.to_reqllm/1" do
    test "produces ReqLLM tools with the never-invoked provider stub" do
      tool = Tool.new(name: "t", description: "d", executor: :human)
      assert [%ReqLLM.Tool{name: "t", description: "d"}] = Tool.to_reqllm([tool])
    end

    test "the provider stub raises if ever invoked" do
      assert_raise RuntimeError, ~r/dispatched by the agent loop/, fn ->
        Tool.__provider_stub__(%{})
      end
    end
  end

  describe "Turn.new/1" do
    test "enforces a scope" do
      assert %Turn{scope: %Scope{}} = Turn.new(scope: Scope.system(), turn_ref: make_ref())

      # Missing scope is caught by the enforced key...
      assert_raise ArgumentError, ~r/scope/, fn -> Turn.new(turn_ref: make_ref()) end

      # ...a non-scope value by the explicit validation.
      assert_raise ArgumentError, ~r/requires a %Agentix.Scope/, fn ->
        Turn.new(scope: :nope)
      end
    end
  end
end
