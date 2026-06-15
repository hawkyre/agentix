defmodule Agentix.ChatTest do
  use ExUnit.Case, async: false

  import Agentix.Test
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Test.MockProvider
  alias Agentix.Tool

  @endpoint Agentix.Test.Endpoint

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id, conn: build_conn()}
  end

  defp start_conversation(id, opts) do
    {:ok, _pid} =
      Conversation.ensure_started(id, config: Config.new(Keyword.merge([model: "mock:test"], opts)))

    :ok
  end

  defp mount_chat(conn, id),
    do: live_isolated(conn, Agentix.Test.ChatLive, session: %{"conversation_id" => id})

  describe "mount + send_message" do
    test "streams a token delta to the hook and stream-inserts the finalized turn", ctx do
      start_conversation(ctx.id, [])
      MockProvider.script(completion("assistant-reply"))

      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      assert render(view) =~ ~s(class="state">idle)

      view |> form("#composer", %{"text" => "user-question"}) |> render_submit()

      # The user message is inserted optimistically; the assistant text is streamed to
      # the JS hook (a push event), not held in an assign.
      assert render(view) =~ "user-question"
      assert_push_event(view, "agentix:delta", %{chunk: "assistant-reply"})

      assert_receive {:turn_completed, _ref}
      # On finalization the assistant message lands in the stream.
      assert render(view) =~ "assistant-reply"
    end
  end

  describe "pending tool call resolves from the UI" do
    test "a gated tool suspends into pending, approving it resumes the turn", ctx do
      tool =
        Tool.new(
          name: "do_thing",
          executor: :server,
          approval: :requires_approval,
          callback: fn _args, _turn -> {:ok, "done"} end
        )

      start_conversation(ctx.id, tools: [tool])
      MockProvider.script([completion("", tool_calls: [{"do_thing", %{}}]), completion("all-done")])

      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      view |> form("#composer", %{"text" => "go"}) |> render_submit()

      assert_receive {:suspended, tool_call_id, :server, _prompt}
      assert render(view) =~ "pending-" <> tool_call_id

      view |> element(".pending button") |> render_click()

      assert_receive {:turn_completed, _ref}
      html = render(view)
      assert html =~ "all-done"
      refute html =~ "pending-" <> tool_call_id
    end
  end

  describe "snapshot ↔ live convergence" do
    test "a reconnect renders the same pending entry as the live suspend", ctx do
      tool =
        Tool.new(
          name: "do_thing",
          executor: :server,
          approval: :requires_approval,
          callback: fn _args, _turn -> {:ok, "done"} end
        )

      start_conversation(ctx.id, tools: [tool])

      MockProvider.script([
        completion("", tool_calls: [{"do_thing", %{"q" => "x"}}]),
        completion("ok")
      ])

      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      view |> form("#composer", %{"text" => "go"}) |> render_submit()
      assert_receive {:suspended, tool_call_id, :server, _prompt}

      # The pending entry seen by the original (live) client...
      live = view |> element("#pending-" <> tool_call_id) |> render()
      # ...must be byte-identical to the one a reconnecting client builds from the snapshot.
      {:ok, view2, _html} = mount_chat(build_conn(), ctx.id)
      snapshot = view2 |> element("#pending-" <> tool_call_id) |> render()

      assert live == snapshot
    end
  end

  describe "delta deduplication" do
    test "a stale delta (seq below what's already applied) is dropped, not re-appended", ctx do
      start_conversation(ctx.id, [])
      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      ref = make_ref()

      send(view.pid, {:thinking_delta, ref, "m1", "AAA", 0})
      send(view.pid, {:thinking_delta, ref, "m1", "BBB", 1})
      assert render(view) =~ "AAABBB"

      # A replayed delta (e.g. buffered across a reconnect) carries an already-applied
      # seq and must be ignored rather than doubling the text.
      send(view.pid, {:thinking_delta, ref, "m1", "AAA", 0})
      html = render(view)
      assert html =~ "AAABBB"
      refute html =~ "AAABBBAAA"
    end
  end

  describe "mid-stream reconnect" do
    test "a second mount seeds the JS hook with the partial assistant text", ctx do
      Application.put_env(:agentix, :pausing_provider, %{text: "partial-text", test_pid: self()})
      Application.put_env(:agentix, :provider, Agentix.Test.PausingProvider)

      start_conversation(ctx.id, [])

      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      view |> form("#composer", %{"text" => "hello"}) |> render_submit()

      # The stream delivered one chunk, then parked the streaming task — the turn is now
      # genuinely mid-stream with partial text accumulated in the agent.
      assert_receive {:agentix_streaming, task_pid}

      # A fresh mount fetches the snapshot and seeds the hook with the partial text.
      {:ok, view2, _html} = mount_chat(build_conn(), ctx.id)
      assert_push_event(view2, "agentix:seed", %{text: "partial-text"})

      send(task_pid, :agentix_release)
      assert_receive {:turn_completed, _ref}
    end
  end
end
