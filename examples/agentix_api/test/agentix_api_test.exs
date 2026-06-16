defmodule AgentixApiTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Test.MockProvider
  alias Agentix.Tool

  test "the optional LiveView and Ecto layers are not compiled in a Tier-1 consumer" do
    # The whole point of the headless tier: neither dep is present, so the compile-gated
    # modules never get defined.
    refute Code.ensure_loaded?(Agentix.Chat)
    refute Code.ensure_loaded?(Agentix.Persistence.Ecto)

    # The core runtime and the default ETS adapter, by contrast, are always available.
    assert Code.ensure_loaded?(Agentix.Conversation)
    assert Code.ensure_loaded?(Agentix.Persistence.ETS)
  end

  test "drives a headless streaming conversation with a :server tool on ETS" do
    install_mock_provider()

    test_pid = self()

    lookup =
      Tool.new(
        name: "lookup",
        executor: :server,
        callback: fn _args, _turn ->
          send(test_pid, :tool_ran)
          {:ok, "the answer is 42"}
        end
      )

    id = "api-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _pid} = AgentixApi.start(id, model: "mock:test", tools: [lookup])
    :ok = AgentixApi.subscribe(id)

    # First model turn calls the tool; once its result is fed back, the second replies.
    MockProvider.script([
      completion("", tool_calls: [{"lookup", %{}}]),
      completion("the answer is 42")
    ])

    :ok = AgentixApi.send_message(id, "what is the answer?")

    # The :server tool auto-dispatched and resolved (no human in the loop)...
    assert_receive :tool_ran, 2_000
    # ...and the streamed reply accumulated off the live-event plane.
    assert AgentixApi.collect_reply() =~ "the answer is 42"
  end
end
