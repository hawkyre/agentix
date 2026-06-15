if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Agentix.Components do
    @moduledoc """
    Default function components for rendering an `Agentix.Chat` conversation.

    These are optional sugar over the headless projection (`Agentix.Chat`): `import
    Agentix.Components` and render the assigns directly, or run `mix
    agentix.gen.components` to copy an editable version into your project and own the
    markup. Every component is overridable — `message/1` exposes a `:bubble` slot, and
    the pending controls switch on `pending[id].kind` (not the executor), so the same UI
    serves a gated `:server` approval and a `:human` elicitation.

    The components emit these `phx-click`/`phx-submit` events for the host to wire (e.g.
    to `Agentix.Chat.resolve/3`):

      * `"approve"` / `"deny"` — `phx-value-id` is the tool-call id (an approval);
      * `"resolve"` — a form submit carrying `tool_call_id` and an `answer`/`result`
        field (an elicitation or client execution).
    """
    use Phoenix.Component

    @doc """
    Renders the message stream, the in-progress streaming message, and any pending
    controls. `messages` accepts a `Phoenix.LiveView` stream or a list of
    `{dom_id, %ReqLLM.Message{}}` pairs.
    """
    attr(:id, :string, default: "agentix-messages")
    attr(:messages, :any, default: [], doc: "a LiveView stream or list of {dom_id, message}")
    attr(:streaming_message, :map, default: nil, doc: "%{id} of the in-progress turn, or nil")
    attr(:pending, :map, default: %{}, doc: "tool_call_id => %{executor, kind, prompt}")

    def message_list(assigns) do
      ~H"""
      <div id={@id} class="agentix-messages" phx-update="stream">
        <.message :for={{dom_id, message} <- @messages} id={dom_id} message={message} />
      </div>

      <.streaming_message :if={@streaming_message} message={@streaming_message} />

      <div class="agentix-pending">
        <.pending :for={{id, entry} <- @pending} id={id} entry={entry} />
      </div>
      """
    end

    @doc """
    Renders one message bubble. Provide a `:bubble` slot to replace the default bubble
    entirely; the slot receives the message.
    """
    attr(:id, :string, default: nil)
    attr(:message, :map, required: true)
    slot(:bubble, doc: "overrides the default bubble; receives the message")

    def message(assigns) do
      ~H"""
      <div id={@id} class={["agentix-message", "agentix-message-#{@message.role}"]}>
        <div :if={@bubble == []} class="agentix-bubble">{message_text(@message)}</div>
        {render_slot(@bubble, @message)}
      </div>
      """
    end

    @doc "Renders the pending affordance for a tool call, switching on its `kind`."
    attr(:id, :string, required: true)
    attr(:entry, :map, required: true)

    def pending(%{entry: %{kind: :approval}} = assigns) do
      ~H"""
      <div id={"pending-#{@id}"} class="agentix-pending-approval">
        <span class="agentix-prompt">{prompt_label(@entry)}</span>
        <button type="button" phx-click="approve" phx-value-id={@id}>Approve</button>
        <button type="button" phx-click="deny" phx-value-id={@id}>Deny</button>
      </div>
      """
    end

    def pending(%{entry: %{kind: :elicitation}} = assigns) do
      ~H"""
      <form id={"pending-#{@id}"} class="agentix-pending-elicitation" phx-submit="resolve">
        <input type="hidden" name="tool_call_id" value={@id} />
        <label class="agentix-prompt">{prompt_label(@entry)}</label>
        <input type="text" name="answer" />
        <button type="submit">Send</button>
      </form>
      """
    end

    def pending(%{entry: %{kind: :client_exec}} = assigns) do
      ~H"""
      <form id={"pending-#{@id}"} class="agentix-pending-client-exec" phx-submit="resolve">
        <input type="hidden" name="tool_call_id" value={@id} />
        <label class="agentix-prompt">{prompt_label(@entry)}</label>
        <input type="text" name="result" />
        <button type="submit">Send</button>
      </form>
      """
    end

    @doc """
    The element the JS streaming hook writes into. Wrap is `phx-update="ignore"`; the
    hook appends text/thinking deltas to the two `data-agentix` child nodes.
    """
    attr(:message, :map, required: true)

    def streaming_message(assigns) do
      ~H"""
      <div
        id={"agentix-stream-#{@message.id}"}
        class="agentix-streaming"
        phx-hook="AgentixStream"
        phx-update="ignore"
        data-msg-id={@message.id}
      >
        <div data-agentix="thinking" class="agentix-thinking"></div>
        <div data-agentix="text" class="agentix-text"></div>
      </div>
      """
    end

    defp message_text(%{content: parts}) when is_list(parts),
      do: parts |> Enum.map(&Map.get(&1, :text)) |> Enum.reject(&is_nil/1) |> Enum.join("")

    defp message_text(_message), do: ""

    defp prompt_label(%{kind: :approval}), do: "Approval required"
    defp prompt_label(%{kind: :elicitation}), do: "Input requested"
    defp prompt_label(%{kind: :client_exec}), do: "Client action requested"
  end
end
