if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Agentix.Chat.Projection do
    @moduledoc """
    Projects a conversation's snapshot and its live-event stream onto LiveView assigns.

    The assigns owned here:

      * `:messages` — a `Phoenix.LiveView.stream/3` of finalized `ReqLLM.Message`s;
      * `:streaming_message` — `%{id, thinking}` for the assistant message currently
        being produced, or `nil`. Its **text is deliberately not an assign** — token
        deltas are pushed to the JS hook so a growing string is never re-diffed
        server-side; only the finalized message lands in `:messages`;
      * `:state` — the agent's current turn state, and `:streaming?` derived from it;
      * `:in_flight_tools` — `%{tool_call_id => %{name, executor, progress}}`;
      * `:pending` — `%{tool_call_id => %{executor, kind, prompt}}` awaiting resolution.

    `attach/3` subscribes **before** reading the snapshot, so no event is lost in the
    gap. The projection is keyed throughout (stream dom-ids, tool-call ids,
    last-write-wins `state`), so replaying an event already reflected in the snapshot
    is a no-op — that idempotence is what makes the subscribe-then-fetch order safe.
    """

    import Phoenix.Component, only: [assign: 3, update: 3]
    import Phoenix.LiveView, only: [connected?: 1, stream: 4, stream_insert: 3, push_event: 3]

    alias Agentix.Agent
    alias Agentix.Events.Publisher
    alias Phoenix.LiveView.Socket
    alias ReqLLM.Message

    @conversation_assign :agentix_conversation_id

    @doc "The assign key holding the bound conversation id."
    @spec conversation_assign() :: atom()
    def conversation_assign, do: @conversation_assign

    @doc """
    Binds `conversation_id` to the socket: subscribes to its topic, reads the snapshot,
    and seeds the assigns and the message stream. A mid-stream snapshot seeds the JS
    hook with the partial assistant text via a `agentix:seed` push event.
    """
    @spec attach(Socket.t(), String.t(), keyword()) ::
            Socket.t()
    def attach(socket, conversation_id, opts \\ []) do
      if connected?(socket) do
        pubsub = Keyword.get(opts, :pubsub, Application.get_env(:agentix, :pubsub, Agentix.PubSub))
        Phoenix.PubSub.subscribe(pubsub, Publisher.topic(conversation_id))
      end

      snapshot = Agent.snapshot(conversation_id)

      socket
      |> assign(@conversation_assign, conversation_id)
      |> assign(:state, snapshot.state)
      |> assign(:streaming?, streaming?(snapshot.state))
      |> assign(:in_flight_tools, snapshot.in_flight_tools)
      |> assign(:pending, snapshot.pending)
      |> stream(:messages, snapshot.messages, dom_id: &dom_id/1)
      |> seed_streaming(snapshot.streaming_message)
    end

    @doc "Optimistically inserts a just-sent user message into the stream."
    @spec insert_user_message(Socket.t(), Message.t()) ::
            Socket.t()
    def insert_user_message(socket, %Message{} = message),
      do: stream_insert(socket, :messages, message)

    @doc "`true` for the members of the live-event union this projection consumes."
    @spec live_event?(term()) :: boolean()
    def live_event?(event) when is_tuple(event) and tuple_size(event) > 0 do
      elem(event, 0) in [
        :state_changed,
        :turn_started,
        :text_delta,
        :thinking_delta,
        :message_completed,
        :tool_call_started,
        :tool_progress,
        :tool_call_resolved,
        :tool_call_errored,
        :suspended,
        :turn_completed,
        :turn_halted,
        :cancelled
      ]
    end

    def live_event?(_event), do: false

    @doc "Applies one live event to the socket assigns. See the module doc for the map."
    @spec apply_event(Socket.t(), Publisher.live_event()) ::
            Socket.t()
    def apply_event(socket, {:state_changed, state}),
      do: socket |> assign(:state, state) |> assign(:streaming?, streaming?(state))

    def apply_event(socket, {:turn_started, _turn_ref}), do: socket

    def apply_event(socket, {:text_delta, _turn_ref, msg_id, chunk}) do
      socket
      |> ensure_streaming(msg_id)
      |> push_event("agentix:delta", %{id: msg_id, chunk: chunk})
    end

    def apply_event(socket, {:thinking_delta, _turn_ref, msg_id, chunk}) do
      socket = ensure_streaming(socket, msg_id)
      sm = socket.assigns.streaming_message
      assign(socket, :streaming_message, %{sm | thinking: sm.thinking <> chunk})
    end

    def apply_event(socket, {:message_completed, _turn_ref, %Message{} = message}) do
      socket
      |> stream_insert(:messages, message)
      |> assign(:streaming_message, nil)
    end

    def apply_event(socket, {:tool_call_started, id, name, executor, _args}) do
      update(
        socket,
        :in_flight_tools,
        &Map.put(&1, id, %{name: name, executor: executor, progress: nil})
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

    def apply_event(socket, {:tool_call_resolved, id, _result}), do: clear_tool(socket, id)
    def apply_event(socket, {:tool_call_errored, id, _reason}), do: clear_tool(socket, id)

    def apply_event(socket, {:suspended, id, executor, prompt}) do
      entry = %{executor: executor, kind: prompt[:kind] || prompt["kind"], prompt: prompt}
      update(socket, :pending, &Map.put(&1, id, entry))
    end

    def apply_event(socket, {:turn_completed, _turn_ref}), do: reset_turn(socket)
    def apply_event(socket, {:turn_halted, _turn_ref, _reason}), do: reset_turn(socket)
    def apply_event(socket, {:cancelled, _turn_ref}), do: reset_turn(socket)

    @doc "`true` while an assistant message is being produced."
    @spec streaming?(atom()) :: boolean()
    def streaming?(state), do: state in [:preparing, :streaming]

    @doc "The DOM id for a message in the `:messages` stream."
    @spec dom_id(Message.t()) :: String.t()
    def dom_id(%Message{metadata: %{"id" => id}}) when is_binary(id), do: "agentix-msg-" <> id

    def dom_id(%Message{}),
      do: "agentix-msg-" <> Integer.to_string(System.unique_integer([:positive]))

    defp seed_streaming(socket, nil), do: assign(socket, :streaming_message, nil)

    defp seed_streaming(socket, %{id: id, text: text, thinking: thinking}) do
      socket
      |> assign(:streaming_message, %{id: id, thinking: thinking})
      |> push_event("agentix:seed", %{id: id, text: text})
    end

    defp ensure_streaming(socket, msg_id) do
      case socket.assigns[:streaming_message] do
        %{id: ^msg_id} -> socket
        _ -> assign(socket, :streaming_message, %{id: msg_id, thinking: ""})
      end
    end

    # A resolved/errored call leaves both the in-flight and pending sets (a suspended
    # call lived in `pending`; a dispatched server call lived in `in_flight_tools`).
    defp clear_tool(socket, id) do
      socket
      |> update(:in_flight_tools, &Map.delete(&1, id))
      |> update(:pending, &Map.delete(&1, id))
    end

    defp reset_turn(socket) do
      socket
      |> assign(:streaming_message, nil)
      |> assign(:streaming?, false)
      |> assign(:in_flight_tools, %{})
    end
  end
end
