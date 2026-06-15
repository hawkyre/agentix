defmodule AgentixComponents do
  @moduledoc """
  Chat components copied from Agentix for you to own and customize.

  Rendered against the `Agentix.Chat` projection assigns. The pending controls switch on
  `pending[id].kind` (`:approval` / `:elicitation` / `:client_exec`), not the executor.
  They emit `"approve"`/`"deny"` (with `phx-value-id`) and a `"resolve"` form submit
  (carrying `tool_call_id` + an `answer`/`result` field) — wire to `Agentix.Chat.resolve/3`.
  """
  use Phoenix.Component

  attr :id, :string, default: "agentix-messages"
  attr :messages, :any, default: [], doc: "a LiveView stream or list of {dom_id, message}"
  attr :streaming_message, :map, default: nil, doc: "%{id} of the in-progress turn, or nil"
  attr :pending, :map, default: %{}, doc: "tool_call_id => %{executor, kind, prompt}"

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

  attr :id, :string, default: nil
  attr :message, :map, required: true
  slot :bubble, doc: "overrides the default bubble; receives the message"

  def message(assigns) do
    ~H"""
    <div id={@id} class={["agentix-message", "agentix-message-#{@message.role}"]}>
      <div :if={@bubble == []} class="agentix-bubble">{message_text(@message)}</div>
      {render_slot(@bubble, @message)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

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

  attr :message, :map, required: true

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
