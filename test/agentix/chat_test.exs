defmodule Agentix.ChatTest do
  use ExUnit.Case, async: false

  import Agentix.Test
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope
  alias Agentix.Test.ChatLive
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

  defp mount_chat(conn, id), do: live_isolated(conn, ChatLive, session: %{"conversation_id" => id})

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

    test "a resolved tool persists as a stream row that a reconnect rebuilds identically",
         ctx do
      tool = Tool.new(name: "lookup", executor: :server, callback: fn _a, _t -> {:ok, "42"} end)
      start_conversation(ctx.id, tools: [tool])
      MockProvider.script([completion("", tool_calls: [{"lookup", %{}}]), completion("done")])

      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      view |> form("#composer", %{"text" => "go"}) |> render_submit()
      assert_receive {:tool_call_resolved, tool_call_id, %{ok: true}}
      assert_receive {:turn_completed, _ref}

      # The resolved tool is a finalized row in the live stream (not cleared at turn end),
      # keyed on the tool-call id...
      dom_id = "agentix-msg-tool-" <> tool_call_id
      assert has_element?(view, "##{dom_id}")
      assert view |> element("##{dom_id} .role") |> render() =~ "tool"

      # ...and a reconnecting client rebuilds the same row from history under the same id.
      {:ok, view2, _html} = mount_chat(build_conn(), ctx.id)
      assert has_element?(view2, "##{dom_id}")
    end
  end

  describe "dom_id/1 — stream keying contract" do
    alias Agentix.Chat.Projection
    alias ReqLLM.Message

    test "a tool row keys on its tool_call_id so a live insert and a reload converge" do
      assert Projection.dom_id(%Message{role: :tool, tool_call_id: "t1"}) == "agentix-msg-tool-t1"
    end

    test "a message with a metadata id keys on it" do
      assert Projection.dom_id(%Message{role: :assistant, metadata: %{"id" => "m1"}}) ==
               "agentix-msg-m1"
    end

    test "a message with neither id falls back to a distinct generated id" do
      one = Projection.dom_id(%Message{role: :user})
      two = Projection.dom_id(%Message{role: :user})
      assert one =~ "agentix-msg-"
      assert one != two
    end
  end

  describe "history pagination" do
    test "seeds only the last page and pages older on demand", ctx do
      start_conversation(ctx.id, [])

      for n <- 1..3 do
        MockProvider.script(completion("reply-#{n}"))
        :ok = Conversation.send_message(ctx.id, "msg-#{n}", Scope.new())
        assert_receive {:turn_completed, _ref}
      end

      # 6 messages (3 turns); a page of 2 events shows only the newest turn.
      {:ok, view, _html} =
        live_isolated(ctx.conn, ChatLive, session: %{"conversation_id" => ctx.id, "page_size" => 2})

      html = render(view)
      assert html =~ "reply-3"
      refute html =~ "reply-1"
      assert has_element?(view, "#load-older")

      # Page back to the start; the control disappears at the head of the log.
      view |> element("#load-older") |> render_click()
      view |> element("#load-older") |> render_click()

      html = render(view)
      assert html =~ "reply-1"
      assert html =~ "reply-3"
      refute has_element?(view, "#load-older")
    end
  end

  describe "streamed content" do
    test "text and thinking deltas push to the hook tagged with kind and seq", ctx do
      start_conversation(ctx.id, [])
      {:ok, view, _html} = mount_chat(ctx.conn, ctx.id)
      ref = make_ref()

      # Both kinds stream to the JS hook (never assigns) carrying the per-message seq the
      # hook uses to drop replayed deltas — the dedup itself lives client-side, like text.
      send(view.pid, {:thinking_delta, ref, "m1", "reasoning", 0})
      assert_push_event(view, "agentix:delta", %{kind: "thinking", chunk: "reasoning", seq: 0})

      send(view.pid, {:text_delta, ref, "m1", "answer", 1})
      assert_push_event(view, "agentix:delta", %{kind: "text", chunk: "answer", seq: 1})
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
