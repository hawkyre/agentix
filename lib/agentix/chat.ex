if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Agentix.Chat do
    @moduledoc """
    The headless LiveView layer: conversation state and verbs, no markup.

    `use Agentix.Chat` in a host LiveView installs an `on_mount` hook that routes a
    conversation's live events into assigns (via `Agentix.Chat.Projection`) and imports
    the verbs below. The host owns the template — it renders its own HEEx against the
    projected assigns (`:messages`, `:streaming_message`, `:state`, `:streaming?`,
    `:in_flight_tools`, `:pending`); default components are a separate, optional layer.

        defmodule MyAppWeb.ChatLive do
          use MyAppWeb, :live_view
          use Agentix.Chat

          def mount(%{"id" => id}, _session, socket) do
            {:ok, attach_conversation(socket, id)}
          end

          def handle_event("send", %{"text" => text}, socket) do
            {:noreply, send_message(socket, text)}
          end
        end

    The in-progress assistant text is streamed to a JS hook (shipped at
    `priv/static/agentix_stream_hook.js`) rather than held in an assign — see
    `Agentix.Chat.Projection`. This module is defined only when `phoenix_live_view` is
    available; headless/API consumers omit the dependency and never load it.
    """

    import Phoenix.Component, only: [assign: 3]
    import Phoenix.LiveView, only: [attach_hook: 4]

    alias Agentix.Chat.Projection
    alias Agentix.Conversation
    alias Agentix.Scope
    alias Phoenix.LiveView.Socket
    alias ReqLLM.Message
    alias ReqLLM.Message.ContentPart

    @doc false
    defmacro __using__(_opts) do
      quote do
        import unquote(__MODULE__),
          only: [
            attach_conversation: 2,
            attach_conversation: 3,
            send_message: 2,
            send_message: 3,
            resolve: 3,
            cancel: 1
          ]

        on_mount({unquote(__MODULE__), :default})
      end
    end

    @doc """
    `on_mount` hook (installed by `use Agentix.Chat`): attaches a `handle_info` hook
    that applies the conversation's live events to the assigns and lets every other
    message fall through to the host LiveView.
    """
    @spec on_mount(:default, map(), map(), Socket.t()) ::
            {:cont, Socket.t()}
    def on_mount(:default, _params, _session, socket) do
      {:cont, attach_hook(socket, :agentix_live_events, :handle_info, &handle_live_event/2)}
    end

    @doc """
    Binds a conversation to the socket: subscribe, read the snapshot, seed the assigns
    and the message stream. Call it from the host's `mount/3` (or `handle_params/3`)
    once the conversation id is known.

    The conversation should be started with its config beforehand (e.g.
    `Agentix.Conversation.ensure_started/2`) or be revivable from persistence — attaching
    only reads and tails it, it never creates one.
    """
    @spec attach_conversation(Socket.t(), String.t(), keyword()) ::
            Socket.t()
    def attach_conversation(socket, conversation_id, opts \\ []),
      do: Projection.attach(socket, conversation_id, opts)

    @doc """
    Sends a user message through the conversation and optimistically streams it into
    `:messages`. Pass `:scope` (an `Agentix.Scope`) in `opts` to attribute the message.

    On success the `:agentix_error` assign is cleared; on failure (e.g. `:busy` for an
    in-flight turn, or `:unknown_conversation` for one that was never started) the
    message is **not** inserted and `:agentix_error` is set to the reason so the host can
    surface it — the input is never dropped silently.
    """
    @spec send_message(Socket.t(), Conversation.message(), keyword()) ::
            Socket.t()
    def send_message(socket, message, opts \\ []) do
      scope = Keyword.get(opts, :scope, Scope.new())

      case Conversation.send_message(conversation_id(socket), message, scope) do
        :ok ->
          socket
          |> assign(:agentix_error, nil)
          |> Projection.insert_user_message(user_message(message))

        {:error, reason} ->
          assign(socket, :agentix_error, reason)
      end
    end

    @doc """
    Resolves a pending tool call — an approval (`:approve` / `%{approved: bool}`) or an
    elicitation answer. Pass `:scope` in a 4-arity `Agentix.resolve/4` call directly for
    a non-default resolver identity.
    """
    @spec resolve(Socket.t(), String.t(), term()) ::
            Socket.t()
    def resolve(socket, tool_call_id, result) do
      Agentix.resolve(conversation_id(socket), tool_call_id, result, Scope.new())
      socket
    end

    @doc "Cancels the in-flight turn (a no-op when idle)."
    @spec cancel(Socket.t()) :: Socket.t()
    def cancel(socket) do
      Conversation.cancel(conversation_id(socket))
      socket
    end

    defp handle_live_event(message, socket) do
      if Projection.live_event?(message) do
        {:halt, Projection.apply_event(socket, message)}
      else
        {:cont, socket}
      end
    end

    defp conversation_id(socket), do: socket.assigns[Projection.conversation_assign()]

    defp user_message(%Message{} = message), do: message

    defp user_message(text) when is_binary(text),
      do: %Message{role: :user, content: [ContentPart.text(text)]}
  end
end
