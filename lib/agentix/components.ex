if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Agentix.Components do
    @moduledoc """
    Default function components for rendering an `Agentix.Chat` conversation.

    These are optional sugar over the headless projection (`Agentix.Chat`): `import
    Agentix.Components` and render the assigns directly, or run `mix
    agentix.gen.components` to copy an editable version into your project and own the
    markup. Every component is overridable — `message/1` exposes a `:bubble` slot, and
    the pending controls switch on `pending[id].kind` (not the executor).

    ## Styling

    The markup uses **Tailwind** utility classes (the stock `neutral` scale plus
    `emerald`/`red`/`amber` semantics, with `darkMode: 'class'`) in a flat, borderless
    style: full-width turn rows separated by hairline dividers. A host on the LiveView
    tier already has Tailwind; no extra config is required beyond enabling class-based
    dark mode. The streaming caret is an optional CSS nicety (`.caret`) the host can add.

    The components emit these `phx-click`/`phx-submit` events for the host to wire (e.g.
    to `Agentix.Chat.resolve/3`):

      * `"approve"` / `"deny"` — `phx-value-id` is the tool-call id (an approval);
      * `"resolve"` — a form submit carrying `tool_call_id` and an `answer`/`result`
        field (an elicitation or client execution).
    """
    use Phoenix.Component

    @doc """
    Renders the conversation: a flat, divider-separated thread of finalized messages,
    then the in-progress assistant turn (running tools + streaming text) and any pending
    controls as their own assistant rows. `messages` accepts a `Phoenix.LiveView` stream
    or a list of `{dom_id, %ReqLLM.Message{}}` pairs.
    """
    attr(:id, :string, default: "agentix-messages")
    attr(:messages, :any, default: [], doc: "a LiveView stream or list of {dom_id, message}")
    attr(:streaming_message, :map, default: nil, doc: "%{id} of the in-progress turn, or nil")
    attr(:in_flight_tools, :map, default: %{}, doc: "tool_call_id => %{name, executor, progress}")
    attr(:pending, :map, default: %{}, doc: "tool_call_id => %{executor, kind, prompt}")

    def message_list(assigns) do
      ~H"""
      <div id={@id} class="divide-y divide-neutral-200/70 dark:divide-neutral-800/70" phx-update="stream">
        <.message :for={{dom_id, message} <- @messages} id={dom_id} message={message} />
      </div>

      <div
        :if={@streaming_message || @in_flight_tools != %{}}
        class="group flex gap-3.5 border-t border-neutral-200/70 py-5 dark:border-neutral-800/70"
      >
        <.avatar role={:assistant} />
        <div class="min-w-0 flex-1">
          <.role_header role={:assistant} />
          <div :if={@in_flight_tools != %{}} class="mb-3 space-y-2">
            <.tool :for={{id, tool} <- @in_flight_tools} id={id} tool={tool} />
          </div>
          <.streaming_message :if={@streaming_message} message={@streaming_message} />
        </div>
      </div>

      <div
        :for={{id, entry} <- @pending}
        class="group flex gap-3.5 border-t border-neutral-200/70 py-5 dark:border-neutral-800/70"
      >
        <.avatar role={:assistant} />
        <div class="min-w-0 flex-1">
          <.role_header role={:assistant} />
          <.pending id={id} entry={entry} />
        </div>
      </div>
      """
    end

    @doc """
    Renders one finalized message as a flat row (avatar + role label + text). Provide a
    `:bubble` slot to replace the default body entirely; the slot receives the message.
    """
    attr(:id, :string, default: nil)
    attr(:message, :map, required: true)
    slot(:bubble, doc: "overrides the default message body; receives the message")

    def message(assigns) do
      ~H"""
      <div id={@id} class="group flex gap-3.5 py-5">
        <.avatar role={@message.role} />
        <div class="min-w-0 flex-1">
          <.role_header role={@message.role} />
          <div :if={@bubble == []} class="text-[15px] leading-relaxed text-neutral-700 dark:text-neutral-200">
            {message_text(@message)}
          </div>
          {render_slot(@bubble, @message)}
        </div>
      </div>
      """
    end

    @doc """
    The element the JS streaming hook writes into (text + thinking child nodes). Rendered
    inside an assistant turn row by `message_list/1`; its children are client-owned
    (`phx-update="ignore"`), so they must stay empty in the markup.
    """
    attr(:message, :map, required: true)

    def streaming_message(assigns) do
      ~H"""
      <div
        id={"agentix-stream-#{@message.id}"}
        phx-hook="AgentixStream"
        phx-update="ignore"
        data-msg-id={@message.id}
      ><div data-agentix="thinking" hidden class="mb-3 whitespace-pre-wrap text-[13px] leading-relaxed text-neutral-500 dark:text-neutral-400"></div><div data-agentix="text" class="caret whitespace-pre-wrap text-[15px] leading-relaxed text-neutral-700 dark:text-neutral-200"></div></div>
      """
    end

    @doc "A running tool call: a bordered row with a spinner and the tool name."
    attr(:id, :string, required: true)
    attr(:tool, :map, required: true)

    def tool(assigns) do
      ~H"""
      <div id={"tool-#{@id}"} class="overflow-hidden rounded-md border border-neutral-200 dark:border-neutral-800">
        <div class="flex items-center gap-2 px-3 py-2 text-[13px]">
          <svg class="h-3.5 w-3.5 animate-spin text-neutral-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2">
            <path d="M21 12a9 9 0 1 1-6.2-8.5" stroke-linecap="round" />
          </svg>
          <span class="font-mono text-[12px] text-neutral-700 dark:text-neutral-200">{@tool.name}</span>
          <span class="text-neutral-400">running</span>
          <span class="ml-auto text-[12px] text-neutral-400">{@tool.executor}</span>
        </div>
      </div>
      """
    end

    @doc "Renders the pending affordance for a tool call, switching on its `kind`."
    attr(:id, :string, required: true)
    attr(:entry, :map, required: true)

    def pending(%{entry: %{kind: :approval}} = assigns) do
      ~H"""
      <div id={"pending-#{@id}"} class="rounded-md border border-amber-300/70 bg-amber-50 px-3.5 py-3 dark:border-amber-500/30 dark:bg-amber-500/10">
        <div class="flex items-start gap-2.5">
          <svg class="mt-0.5 h-4 w-4 shrink-0 text-amber-600 dark:text-amber-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M12 9v4M12 17h.01" />
            <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
          </svg>
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-semibold text-amber-900 dark:text-amber-200">Permission required</div>
            <div class="mt-0.5 text-[13px] text-amber-800/90 dark:text-amber-200/80">{prompt_label(@entry)}</div>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <button type="button" phx-click="approve" phx-value-id={@id} class="rounded-md bg-neutral-900 px-3 py-1.5 text-[13px] font-medium text-neutral-50 transition hover:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-white">
                Allow
              </button>
              <button type="button" phx-click="deny" phx-value-id={@id} class="rounded-md px-3 py-1.5 text-[13px] font-medium text-neutral-500 transition hover:bg-neutral-200/70 dark:text-neutral-400 dark:hover:bg-neutral-800/70">
                Deny
              </button>
            </div>
          </div>
        </div>
      </div>
      """
    end

    def pending(assigns) do
      ~H"""
      <form id={"pending-#{@id}"} phx-submit="resolve" class="rounded-md border border-neutral-200 bg-neutral-100/60 px-3.5 py-3 dark:border-neutral-800 dark:bg-neutral-900/50">
        <input type="hidden" name="tool_call_id" value={@id} />
        <label class="text-[13px] font-medium text-neutral-700 dark:text-neutral-200">{prompt_label(@entry)}</label>
        <div class="mt-2 flex gap-2">
          <input type="text" name={input_name(@entry)} placeholder="Your response…" class="flex-1 rounded-md border border-neutral-300 bg-white px-2.5 py-1.5 text-[13px] text-neutral-800 placeholder:text-neutral-400 focus:border-neutral-400 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100" />
          <button type="submit" class="rounded-md bg-neutral-900 px-3 py-1.5 text-[13px] font-medium text-neutral-50 transition hover:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-white">
            Send
          </button>
        </div>
      </form>
      """
    end

    attr(:role, :atom, required: true)

    defp role_header(assigns) do
      ~H"""
      <div class="mb-1 flex items-center gap-2">
        <span class="text-[13px] font-semibold">{role_label(@role)}</span>
      </div>
      """
    end

    attr(:role, :atom, required: true)

    defp avatar(%{role: :user} = assigns) do
      ~H"""
      <div class="mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-200 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300">
        <svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <path d="M20 21a8 8 0 0 0-16 0" />
          <circle cx="12" cy="7" r="4" />
        </svg>
      </div>
      """
    end

    defp avatar(assigns) do
      ~H"""
      <div class="mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-900 text-neutral-50 dark:bg-neutral-100 dark:text-neutral-900">
        <svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <path d="M12 2l2.4 5.6L20 10l-5.6 2.4L12 18l-2.4-5.6L4 10l5.6-2.4z" />
        </svg>
      </div>
      """
    end

    defp role_label(:user), do: "You"
    defp role_label(:assistant), do: "Assistant"
    defp role_label(:tool), do: "Tool"
    defp role_label(role), do: role |> to_string() |> String.capitalize()

    defp message_text(%{content: parts}) when is_list(parts),
      do: parts |> Enum.map(&Map.get(&1, :text)) |> Enum.reject(&is_nil/1) |> Enum.join("")

    defp message_text(_message), do: ""

    defp prompt_label(%{kind: :approval}), do: "Approval required to continue."
    defp prompt_label(%{kind: :elicitation}), do: "The assistant needs more information."
    defp prompt_label(%{kind: :client_exec}), do: "A client action is requested."
    defp prompt_label(_entry), do: "Pending"

    defp input_name(%{kind: :client_exec}), do: "result"
    defp input_name(_entry), do: "answer"
  end
end
