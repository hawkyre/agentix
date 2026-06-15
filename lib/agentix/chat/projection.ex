if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Agentix.Chat.Projection do
    @moduledoc """
    Projects a conversation's snapshot and its live-event stream onto LiveView assigns.

    The assigns owned here:

      * `:messages` — a `Phoenix.LiveView.stream/3` of finalized `ReqLLM.Message`s;
      * `:streaming_message` — `%{id}` for the assistant message currently being produced,
        or `nil`. Its **text and thinking are deliberately not assigns** — both stream as
        deltas pushed to the JS hook (tagged with `kind`) so a growing string is never
        re-diffed server-side; only the finalized message lands in `:messages`;
      * `:state` — the agent's current turn state, and `:streaming?` derived from it;
      * `:in_flight_tools` — `%{tool_call_id => %{name, executor, status}}` for calls still
        running (`status: :running`); a suspended call moves to `:pending`, and a resolved
        call moves into `:messages` as a finalized tool row (so live and reload converge);
      * `:pending` — `%{tool_call_id => %{executor, kind, prompt}}` awaiting resolution.

    `attach/3` subscribes **before** reading the snapshot, so no event is lost in the
    gap. Keyed entities (stream dom-ids, tool-call ids, last-write-wins `state`) are
    idempotent under replay; **streamed deltas are not keyed**, so each carries a
    monotonic `seq` and the snapshot reports the count so far — a delta already covered
    by the snapshot (`seq` below the seeded value) is dropped rather than double-applied.
    The snapshot and the live stream build identical `:pending`/`:in_flight_tools` entry
    shapes, so a reconnect and a never-disconnected client converge.
    """

    import Phoenix.Component, only: [assign: 3, update: 3]

    import Phoenix.LiveView,
      only: [connected?: 1, stream: 4, stream_insert: 3, stream_insert: 4, push_event: 3]

    alias Agentix.Agent
    alias Agentix.Events.Publisher
    alias Agentix.Persistence
    alias Phoenix.LiveView.Socket
    alias ReqLLM.Message
    alias ReqLLM.Message.ContentPart

    @conversation_assign :agentix_conversation_id
    @default_page_size 50

    @live_event_tags ~w(state_changed turn_started text_delta thinking_delta message_completed
                        tool_call_started tool_progress tool_call_resolved tool_call_errored
                        suspended turn_completed turn_halted cancelled)a

    @doc "The assign key holding the bound conversation id."
    @spec conversation_assign() :: atom()
    def conversation_assign, do: @conversation_assign

    @doc """
    Binds `conversation_id` to the socket: subscribes to its topic, reads the snapshot,
    and seeds the assigns and the message stream. A mid-stream snapshot seeds the JS
    hook with the partial assistant text via a `agentix:seed` push event.

    The topic's pub/sub server is resolved the same way the agent publishes (an explicit
    `:pubsub` opt, else the conversation's configured pub/sub, else the default), so the
    subscriber and publisher never land on different buses.
    """
    @spec attach(Socket.t(), String.t(), keyword()) :: Socket.t()
    def attach(socket, conversation_id, opts \\ []) do
      if connected?(socket) do
        pubsub = resolve_pubsub(conversation_id, opts)
        Phoenix.PubSub.subscribe(pubsub, Publisher.topic(conversation_id))
      end

      page_size = Keyword.get(opts, :page_size, @default_page_size)
      snapshot = Agent.snapshot(conversation_id, limit: page_size)

      socket
      |> assign(@conversation_assign, conversation_id)
      |> assign(:agentix_page_size, page_size)
      |> assign(:agentix_oldest_seq, snapshot.history_cursor)
      |> assign(:agentix_more?, snapshot.more?)
      |> assign(:state, snapshot.state)
      |> assign(:streaming?, streaming?(snapshot.state))
      |> assign(:in_flight_tools, snapshot.in_flight_tools)
      |> assign(:pending, snapshot.pending)
      # Has the current assistant turn already shown its header? Continuation rows
      # (tools, later streaming, pending) render headerless once it has, so a turn
      # never shows a second "Assistant" header.
      |> assign(:agentix_assistant_open, false)
      |> stream(:messages, snapshot.messages, dom_id: &dom_id/1)
      |> seed_streaming(snapshot.streaming_message)
    end

    @doc """
    Pages one older window into the `:messages` stream (prepended above the current
    oldest), advancing `:agentix_oldest_seq` and `:agentix_more?`. A no-op when there is
    nothing older.
    """
    @spec load_older(Socket.t()) :: Socket.t()
    def load_older(%{assigns: %{agentix_more?: true, agentix_oldest_seq: cursor}} = socket)
        when is_integer(cursor) do
      conversation_id = socket.assigns[@conversation_assign]
      page = Agent.history(conversation_id, before: cursor, limit: socket.assigns.agentix_page_size)

      socket
      # Insert oldest-last so the page ends up ascending above the existing messages.
      |> then(
        &Enum.reduce(Enum.reverse(page.messages), &1, fn m, acc ->
          stream_insert(acc, :messages, m, at: 0)
        end)
      )
      |> assign(:agentix_oldest_seq, page.cursor || cursor)
      |> assign(:agentix_more?, page.more?)
    end

    def load_older(socket), do: socket

    @doc "Optimistically inserts a just-sent user message into the stream."
    @spec insert_user_message(Socket.t(), Message.t()) :: Socket.t()
    def insert_user_message(socket, %Message{} = message),
      do: stream_insert(socket, :messages, message)

    @doc "`true` for the members of the live-event union this projection consumes."
    @spec live_event?(term()) :: boolean()
    def live_event?(event) when is_tuple(event) and tuple_size(event) > 0,
      do: elem(event, 0) in @live_event_tags

    def live_event?(_event), do: false

    @doc "Applies one live event to the socket assigns. See the module doc for the map."
    @spec apply_event(Socket.t(), Publisher.live_event()) :: Socket.t()
    def apply_event(socket, {:state_changed, state}),
      do: socket |> assign(:state, state) |> assign(:streaming?, streaming?(state))

    def apply_event(socket, {:turn_started, _turn_ref}), do: socket

    def apply_event(socket, {:text_delta, _turn_ref, msg_id, chunk, seq}) do
      socket
      |> ensure_streaming(msg_id)
      |> push_event("agentix:delta", %{id: msg_id, kind: "text", chunk: chunk, seq: seq})
    end

    def apply_event(socket, {:thinking_delta, _turn_ref, msg_id, chunk, seq}) do
      socket
      |> ensure_streaming(msg_id)
      |> push_event("agentix:delta", %{id: msg_id, kind: "thinking", chunk: chunk, seq: seq})
    end

    def apply_event(socket, {:message_completed, _turn_ref, %Message{role: role} = message}) do
      socket
      |> stream_insert(:messages, message)
      |> assign(:streaming_message, nil)
      |> assign(
        :agentix_assistant_open,
        role == :assistant or socket.assigns.agentix_assistant_open
      )
    end

    def apply_event(socket, {:tool_call_started, id, name, executor, _args}) do
      update(
        socket,
        :in_flight_tools,
        &Map.put(&1, id, %{name: name, executor: executor, status: :running})
      )
    end

    def apply_event(socket, {:tool_progress, id, progress}) do
      update(socket, :in_flight_tools, fn tools ->
        case tools do
          %{^id => entry} -> Map.put(tools, id, %{entry | progress: progress})
          _ -> tools
        end
      end)
    end

    def apply_event(socket, {:tool_call_resolved, id, result}),
      do: finalize_tool(socket, id, :ok, result)

    def apply_event(socket, {:tool_call_errored, id, reason}),
      do: finalize_tool(socket, id, :error, reason)

    def apply_event(socket, {:suspended, id, executor, prompt}) do
      entry = %{
        executor: executor,
        kind: prompt[:kind] || prompt["kind"],
        prompt: prompt_args(prompt)
      }

      socket
      # A suspended call is awaiting input, not running — move it out of in_flight.
      |> update(:in_flight_tools, &Map.delete(&1, id))
      |> update(:pending, &Map.put(&1, id, entry))
    end

    def apply_event(socket, {:turn_completed, _turn_ref}), do: reset_turn(socket)
    def apply_event(socket, {:turn_halted, _turn_ref, _reason}), do: reset_turn(socket)
    def apply_event(socket, {:cancelled, _turn_ref}), do: reset_turn(socket)

    @doc "`true` while an assistant message is being produced."
    @spec streaming?(atom()) :: boolean()
    def streaming?(state), do: state in [:preparing, :streaming]

    @doc "The DOM id for a message in the `:messages` stream."
    @spec dom_id(Message.t()) :: String.t()
    # Tool rows key off the tool-call id so the same row inserted live (on resolve) and
    # seeded from history (on reconnect/reload) collapse to one stream node.
    def dom_id(%Message{role: :tool, tool_call_id: id}) when is_binary(id),
      do: "agentix-msg-tool-" <> id

    def dom_id(%Message{metadata: %{"id" => id}}) when is_binary(id), do: "agentix-msg-" <> id

    def dom_id(%Message{}),
      do: "agentix-msg-" <> Integer.to_string(System.unique_integer([:positive]))

    defp resolve_pubsub(conversation_id, opts) do
      case Keyword.fetch(opts, :pubsub) do
        {:ok, pubsub} -> pubsub
        :error -> conversation_id |> Persistence.get_conversation() |> settings_pubsub()
      end
    end

    defp settings_pubsub(%{settings: settings}) when is_map(settings),
      do: Publisher.resolve_pubsub(settings)

    defp settings_pubsub(_conversation), do: Publisher.resolve_pubsub(%{})

    defp prompt_args(prompt) when is_map(prompt), do: prompt[:args] || prompt["args"]
    defp prompt_args(prompt), do: prompt

    defp seed_streaming(socket, nil), do: assign(socket, :streaming_message, nil)

    defp seed_streaming(socket, %{id: id, text: text, thinking: thinking, seq: seq}) do
      # Seed both content nodes from the snapshot; `seq` is the shared delta baseline, so a
      # replayed delta of either kind (seq below it) is dropped by the hook.
      socket
      |> assign(:streaming_message, %{id: id})
      |> push_event("agentix:seed", %{id: id, kind: "text", text: text, seq: seq})
      |> push_event("agentix:seed", %{id: id, kind: "thinking", text: thinking, seq: seq})
    end

    defp ensure_streaming(socket, msg_id) do
      case socket.assigns[:streaming_message] do
        %{id: ^msg_id} -> socket
        _ -> assign(socket, :streaming_message, %{id: msg_id})
      end
    end

    # A resolved/errored call becomes a finalized tool row in the `:messages` stream — a
    # permanent timeline item under the assistant turn, exactly like a completed message —
    # and leaves the live in-flight + pending sets. This makes the live turn converge with
    # what a reconnect/reload renders from history (`Agent.history/2`).
    defp finalize_tool(socket, id, status, result) do
      name = get_in(socket.assigns.in_flight_tools, [id, :name])

      socket
      |> stream_insert(:messages, tool_message(id, name, status, result))
      |> update(:in_flight_tools, &Map.delete(&1, id))
      |> update(:pending, &Map.delete(&1, id))
    end

    defp tool_message(id, name, status, result) do
      %Message{
        role: :tool,
        tool_call_id: id,
        content: [ContentPart.text(encode_result(result))],
        metadata: %{"tool_name" => name, "tool_status" => to_string(status)}
      }
    end

    defp encode_result(result) when is_binary(result), do: result
    defp encode_result(result), do: inspect(result)

    defp reset_turn(socket) do
      socket
      |> assign(:streaming_message, nil)
      |> assign(:streaming?, false)
      |> assign(:in_flight_tools, %{})
      |> assign(:pending, %{})
      |> assign(:agentix_assistant_open, false)
    end
  end
end
