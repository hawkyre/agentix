defmodule AgentixDemoWeb.ChatLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Agentix.Test

  alias Agentix.Events.Publisher
  alias Agentix.Persistence.Ecto.Event
  alias Agentix.Test.MockProvider

  @endpoint AgentixDemoWeb.Endpoint

  # The test process and the LiveView each receive PubSub events independently, so after a
  # turn completes the LiveView may not have applied `message_completed` to its stream the
  # instant we render. Poll render briefly until the expected text appears.
  defp render_until(live, text, tries \\ 100) do
    html = render(live)

    cond do
      html =~ text -> html
      tries == 0 -> flunk("never rendered #{inspect(text)}.\n\n#{html}")
      true -> Process.sleep(10) && render_until(live, text, tries - 1)
    end
  end

  setup do
    install_mock_provider()

    # Conversation agents are long-lived (registered, never auto-stopped). Terminate every one
    # after the test so an orphan doesn't outlive this test's sandbox checkout and crash (or
    # contend) on the next test's shared connection.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Agentix.ConversationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(Agentix.ConversationSupervisor, pid)
      end
    end)

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

  test "a gated :server tool suspends for approval, then runs and shows its result inspector",
       %{id: id, conn: conn} do
    MockProvider.script([
      completion("", tool_calls: [{"get_weather", %{"city" => "Tokyo"}}]),
      completion("Here is your forecast.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "weather in Tokyo?"}) |> render_submit()

    assert_receive {:suspended, tcid, _executor, _prompt}, 2_000
    assert render(live) =~ "Permission required"

    live |> element("button[phx-value-id='#{tcid}']", "Allow") |> render_click()
    assert_receive {:turn_completed, _ref}, 2_000

    html = render_until(live, "Here is your forecast.")
    # The :server callback ran and its result shows in the expandable inspector.
    assert html =~ "It&#39;s 21°C and sunny in Tokyo."
    assert html =~ "<details"
  end

  test "denying a gated :server tool resolves it without running the tool", %{id: id, conn: conn} do
    MockProvider.script([
      completion("", tool_calls: [{"get_weather", %{"city" => "Tokyo"}}]),
      completion("No problem, skipping that.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "weather in Tokyo?"}) |> render_submit()

    assert_receive {:suspended, tcid, _executor, _prompt}, 2_000
    live |> element("button[phx-value-id='#{tcid}']", "Deny") |> render_click()
    assert_receive {:turn_completed, _ref}, 2_000

    html = render_until(live, "No problem, skipping that.")
    # The callback never ran, so the weather result is absent.
    refute html =~ "21°C and sunny in Tokyo"
  end

  test "a non-gated :server tool (calculator) runs inline and shows its result", %{
    id: id,
    conn: conn
  } do
    MockProvider.script([
      completion("", tool_calls: [{"calculator", %{"expression" => "6 * 7"}}]),
      completion("Math done.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "what is 6 * 7"}) |> render_submit()

    assert_receive {:turn_completed, _ref}, 2_000
    html = render_until(live, "Math done.")
    assert html =~ "6 * 7 = 42"
  end
end
