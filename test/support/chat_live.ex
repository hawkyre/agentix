if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Agentix.Test.ChatLive do
    @moduledoc false
    # A minimal host LiveView exercising the headless `Agentix.Chat` layer. The
    # conversation must already be started; its id is passed through the session.
    use Phoenix.LiveView
    use Agentix.Chat

    @impl Phoenix.LiveView
    def mount(_params, %{"conversation_id" => id}, socket) do
      {:ok, attach_conversation(socket, id)}
    end

    @impl Phoenix.LiveView
    def render(assigns) do
      ~H"""
      <div class="state">{@state}</div>
      <div class="streaming">{to_string(@streaming?)}</div>

      <form id="composer" phx-submit="send">
        <input type="text" name="text" />
      </form>

      <div id="messages" phx-update="stream">
        <div :for={{dom_id, message} <- @streams.messages} id={dom_id} class="message">
          <span class="role">{to_string(message.role)}</span>
          <span class="text">{message_text(message)}</span>
        </div>
      </div>

      <div
        :if={@streaming_message}
        id={"agentix-stream-" <> @streaming_message.id}
        class="stream-target"
        phx-hook="AgentixStream"
        phx-update="ignore"
        data-msg-id={@streaming_message.id}
      >
      </div>

      <div :if={@streaming_message} class="thinking">{@streaming_message.thinking}</div>

      <div :for={{id, entry} <- @pending} id={"pending-" <> id} class="pending">
        <span class="kind">{to_string(entry.kind)}</span>
        <span class="prompt">{inspect(entry.prompt)}</span>
        <button phx-click="approve" phx-value-id={id}>approve</button>
      </div>
      """
    end

    @impl Phoenix.LiveView
    def handle_event("send", %{"text" => text}, socket) do
      {:noreply, send_message(socket, text)}
    end

    def handle_event("approve", %{"id" => id}, socket) do
      {:noreply, resolve(socket, id, :approve)}
    end

    def handle_event("cancel", _params, socket) do
      {:noreply, cancel(socket)}
    end

    defp message_text(%ReqLLM.Message{content: content}) when is_list(content),
      do: Enum.map_join(content, "", &(Map.get(&1, :text) || ""))

    defp message_text(_message), do: ""
  end
end
