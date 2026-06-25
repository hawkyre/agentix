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
    # after the test so an orphan doesn't outlive it and contend on the next test's connection.
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

  test "a non-gated :server tool (search_code) runs inline and shows its real result", %{
    id: id,
    conn: conn
  } do
    MockProvider.script([
      completion("", tool_calls: [{"search_code", %{"query" => "defmodule Agentix.Hook do"}}]),
      completion("Found it in the Hook module.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "where is the Hook module?"}) |> render_submit()

    assert_receive {:turn_completed, _ref}, 2_000
    html = render_until(live, "Found it in the Hook module.")
    # The real search_code callback ran against the repo — its file:line result is in the inspector.
    assert html =~ "lib/agentix/hook.ex"
    assert html =~ "<details"

    # Durability: the turn's events were persisted to Postgres through the Ecto adapter.
    assert AgentixDemo.Repo.aggregate(Event, :count) > 0
  end

  test "the gated :server tool (run_tests) suspends for approval, then runs and shows its result",
       %{id: id, conn: conn} do
    MockProvider.script([
      completion("", tool_calls: [{"run_tests", %{"path" => "test/agentix/hook_test.exs"}}]),
      completion("All green.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "run the hook tests"}) |> render_submit()

    assert_receive {:suspended, tcid, _executor, _prompt}, 2_000
    assert render(live) =~ "Permission required"

    live |> element("button[phx-value-id='#{tcid}']", "Allow") |> render_click()
    assert_receive {:turn_completed, _ref}, 2_000

    html = render_until(live, "All green.")
    # run_tests is stubbed in the test env (config :agentix_demo, :stub_tools, true).
    assert html =~ "would run: mix test test/agentix/hook_test.exs"
    assert html =~ "<details"
  end

  test "denying the gated run_tests resolves it without running anything", %{id: id, conn: conn} do
    MockProvider.script([
      completion("", tool_calls: [{"run_tests", %{"path" => "test/agentix/hook_test.exs"}}]),
      completion("Skipped the tests.")
    ])

    {:ok, live, _html} = live(conn, "/c/" <> id)
    live |> form("form[phx-submit='send']", %{"text" => "run the tests"}) |> render_submit()

    assert_receive {:suspended, tcid, _executor, _prompt}, 2_000
    live |> element("button[phx-value-id='#{tcid}']", "Deny") |> render_click()
    assert_receive {:turn_completed, _ref}, 2_000

    html = render_until(live, "Skipped the tests.")
    refute html =~ "would run: mix test"
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
