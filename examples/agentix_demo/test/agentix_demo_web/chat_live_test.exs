defmodule AgentixDemoWeb.ChatLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Agentix.Test

  alias Agentix.Events.Publisher
  alias Agentix.Persistence.Ecto.Event
  alias Agentix.Test.MockProvider

  @endpoint AgentixDemoWeb.Endpoint

  setup do
    # Shared-mode sandbox: the conversation agent and the LiveView run in their own
    # processes but must see the test's transaction (async: false makes this safe).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AgentixDemo.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(AgentixDemo.Repo, {:shared, self()})

    install_mock_provider()

    id = "demo-" <> Integer.to_string(System.unique_integer([:positive]))
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  test "streams a reply and resolves a HITL elicitation end-to-end", %{id: id} do
    MockProvider.script([
      completion("", tool_calls: [{"ask_user", %{}}]),
      completion("Thanks — all set.")
    ])

    conn = Plug.Test.init_test_session(build_conn(), %{"conversation_id" => id})
    {:ok, live, _html} = live(conn, "/")

    live |> form("form[phx-submit='send']", %{"text" => "help me"}) |> render_submit()

    # The :human tool suspends, awaiting an answer (elicitation) — the pending form renders.
    assert_receive {:suspended, tool_call_id, :human, _prompt}, 2_000
    assert render(live) =~ "pending-" <> tool_call_id

    # Submit the answer through the pending form; the turn resumes and streams the reply.
    live |> form("#pending-" <> tool_call_id, %{"answer" => "yes please"}) |> render_submit()

    assert_receive {:turn_completed, _ref}, 2_000
    assert render(live) =~ "Thanks — all set."

    # Durability: the turn's events were persisted to Postgres through the Ecto adapter.
    assert AgentixDemo.Repo.aggregate(Event, :count) > 0
  end
end
