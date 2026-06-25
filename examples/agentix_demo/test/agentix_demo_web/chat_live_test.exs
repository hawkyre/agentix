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
    {:ok, id: id, conn: Plug.Test.init_test_session(build_conn(), %{})}
  end

  test "streams a reply and resolves a HITL elicitation end-to-end", %{id: id, conn: conn} do
    MockProvider.script([
      completion("", tool_calls: [{"ask_user", %{}}]),
      completion("Thanks — all set.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)

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

  test "a page reload reattaches to the same conversation and restores history", %{
    id: id,
    conn: conn
  } do
    MockProvider.script([completion("Echoed back to you.")])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "remember this"}) |> render_submit()
    assert_receive {:turn_completed, _ref}, 2_000
    assert render(live) =~ "Echoed back to you."

    # A fresh mount of the same URL (a reload) reloads the conversation from Postgres.
    {:ok, reloaded, html} = live(conn, "/c/" <> id)
    assert html =~ "remember this"
    assert render(reloaded) =~ "Echoed back to you."
  end

  test "the theme toggle flips the server-side :theme assign", %{id: id, conn: conn} do
    {:ok, live, _html} = live(conn, "/c/" <> id)
    assert render(live) =~ ~s(data-theme="light")

    live |> element("#theme-toggle") |> render_click()
    assert render(live) =~ ~s(data-theme="dark")

    live |> element("#theme-toggle") |> render_click()
    assert render(live) =~ ~s(data-theme="light")
  end

  test "visiting / redirects to a canonical /c/:id conversation URL", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/c/" <> _id}}} = live(conn, "/")
  end
end
