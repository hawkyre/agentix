defmodule Agentix.Persistence.EctoRevivalTest do
  @moduledoc """
  The durable-suspension headline against a real Postgres: a conversation killed while
  suspended on a HITL tool must revive — reading its pending state back from the database,
  not from in-process memory — and accept a late resolution. Tagged `:postgres`
  (`mix test --include postgres`).
  """
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.EctoCase
  alias Agentix.Test.MockProvider
  alias Agentix.Tool

  @moduletag :postgres

  setup_all do: EctoCase.start!()

  setup do
    install_mock_provider()
    id = "conv-rev-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(opts), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if !fun.() do
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  test "suspended HITL survives a kill and resolves from Postgres state", %{id: id} do
    ask = Tool.new(name: "ask", executor: :human)

    MockProvider.script([
      completion("", tool_calls: [{"ask", %{"prompt" => "name?"}}]),
      completion("Hi Bob")
    ])

    {:ok, pid} = Conversation.ensure_started(id, config: config(tools: [ask]))
    :ok = Conversation.send_message(id, "greet", Scope.new())
    assert_receive {:suspended, tool_call_id, :human, _prompt}

    # The pending tool call is durably in Postgres before the kill.
    assert [%{id: ^tool_call_id, status: :pending}] = Persistence.pending_tool_calls(id)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    wait_until(fn ->
      match?([{new_pid, _}] when new_pid != pid, Registry.lookup(Agentix.Registry, id))
    end)

    # The revived agent rehydrated `awaiting_input` from the database and accepts the
    # late resolution rather than returning `{:error, :stale}`.
    assert :ok = Agentix.resolve(id, tool_call_id, "Bob")
    assert_receive {:turn_completed, _ref}
    assert Persistence.get_tool_call(tool_call_id).status == :resolved
  end
end
