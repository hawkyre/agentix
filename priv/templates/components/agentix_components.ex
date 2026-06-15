  defmodule AgentixComponents do
    @moduledoc """
    Default function components for rendering an `Agentix.Chat` conversation.

    Optional sugar over the headless projection (`Agentix.Chat`): `import
    AgentixComponents` and render the assigns, or run `mix agentix.gen.components` to
    copy an editable version into your project. `message/1` exposes a `:bubble` slot;
    the pending controls switch on `pending[id].kind` (not the executor).

    ## Styling

    Tailwind utility classes (stock `neutral` scale + `emerald`/`red`/`amber` semantics,
    `darkMode: 'class'`) in a flat, borderless style — full-width turn rows on hairline
    dividers. Two small extras the host opts into:

      * **grouping** — give the thread the `agentix-thread` class to collapse consecutive
        same-role rows (the CSS lives in `AgentixComponents.css/0`);
      * **JS hooks** — `AgentixStream` (streaming text) and `AgentixComposer`
        (auto-grow + Enter-to-send), shipped at `priv/static/agentix_stream_hook.js`.

    Interactive controls emit `phx-click`/`phx-submit` events for the host to wire to
    `Agentix.Chat`: `"send"` (composer), `"approve"`/`"deny"` (`phx-value-id`), and
    `"resolve"` (a form carrying `tool_call_id` + `answer`/`result`).
    """
    use Phoenix.Component

    @doc """
    Renders the conversation: a grouped thread of finalized messages, the in-progress
    assistant turn (running tools + streaming text), and pending controls. `messages`
    accepts a `Phoenix.LiveView` stream or a list of `{dom_id, %ReqLLM.Message{}}` pairs.
    """
    attr(:id, :string, default: "agentix-messages")
    attr(:messages, :any, default: [])
    attr(:streaming_message, :map, default: nil)
    attr(:in_flight_tools, :map, default: %{})
    attr(:pending, :map, default: %{})

    attr(:assistant_open, :boolean,
      default: false,
      doc:
        "true once the current assistant turn has shown a header; continuation rows then render headerless"
    )

    def message_list(assigns) do
      ~H"""
      <div
        id={@id}
        class="agentix-thread divide-y divide-neutral-200/70 dark:divide-neutral-800/70"
        phx-update="stream"
      >
        <.message :for={{dom_id, message} <- @messages} id={dom_id} message={message} />
      </div>

      <.assistant_turn :if={@streaming_message || @in_flight_tools != %{}} open={@assistant_open}>
        <div :if={@in_flight_tools != %{}} class="mb-3 space-y-2">
          <.tool
            :for={{id, t} <- @in_flight_tools}
            id={id}
            name={t.name}
            status={Map.get(t, :status, :running)}
            meta={Map.get(t, :meta)}
          />
        </div>
        <.streaming_message :if={@streaming_message} message={@streaming_message} />
      </.assistant_turn>

      <.assistant_turn :for={{id, entry} <- @pending} open={@assistant_open}>
        <.pending id={id} entry={entry} />
      </.assistant_turn>
      """
    end

    # An assistant continuation row: shows the avatar + header only when the turn has
    # not opened one yet (`open` false); otherwise it's a headerless continuation that
    # merges with the assistant block above — so a turn never repeats the header.
    attr(:open, :boolean, required: true)
    slot(:inner_block, required: true)

    defp assistant_turn(assigns) do
      ~H"""
      <div
        class={[
          "agentix-row group flex gap-3.5",
          if(@open,
            do: "-mt-3 pb-5 pt-1",
            else: "border-t border-neutral-200/70 py-5 dark:border-neutral-800/70"
          )
        ]}
        data-role="assistant"
      >
        <.avatar :if={!@open} role={:assistant} />
        <div :if={@open} class="mt-0.5 h-7 w-7 shrink-0" aria-hidden="true"></div>
        <div class="min-w-0 flex-1">
          <.role_header :if={!@open} role={:assistant} />
          {render_slot(@inner_block)}
        </div>
      </div>
      """
    end

    @doc """
    Renders one finalized message as a flat row. A `:bubble` slot replaces the default
    body. The `data-role` attribute drives consecutive-row grouping (see `css/0`).
    """
    attr(:id, :string, default: nil)
    attr(:message, :map, required: true)
    slot(:bubble)

    def message(assigns) do
      ~H"""
      <div id={@id} class="agentix-row group flex gap-3.5 py-5" data-role={@message.role}>
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

    @doc "The element the JS streaming hook writes into (text + thinking child nodes)."
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

    @doc "A collapsed reasoning panel for a finalized turn's thinking."
    attr(:label, :string, default: "Reasoning")
    slot(:inner_block, required: true)

    def reasoning(assigns) do
      ~H"""
      <details class="rounded-md border border-neutral-200 bg-neutral-100/60 dark:border-neutral-800 dark:bg-neutral-900/50">
        <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 text-[13px] text-neutral-500 dark:text-neutral-400">
          <svg class="agentix-chev h-3.5 w-3.5 transition-transform" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M9 6l6 6-6 6" />
          </svg>
          <span class="font-medium">{@label}</span>
        </summary>
        <div class="border-t border-neutral-200 px-3 py-2.5 text-[13px] leading-relaxed text-neutral-500 dark:border-neutral-800 dark:text-neutral-400">
          {render_slot(@inner_block)}
        </div>
      </details>
      """
    end

    @doc "A tool call row. `status` is `:running` | `:ok` | `:error`; `meta` is optional."
    attr(:id, :string, required: true)
    attr(:name, :string, required: true)
    attr(:status, :atom, default: :running)
    attr(:meta, :string, default: nil)

    def tool(assigns) do
      ~H"""
      <div id={"tool-#{@id}"} class={["overflow-hidden rounded-md border", tool_border(@status)]}>
        <div class="flex items-center gap-2 px-3 py-2 text-[13px]">
          <.tool_icon status={@status} />
          <span class={["font-mono text-[12px]", tool_text(@status)]}>{@name}</span>
          <span :if={@meta} class={["text-[12px]", tool_meta(@status)]}>{@meta}</span>
          <span class="ml-auto text-[12px] text-neutral-400">{tool_label(@status)}</span>
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
          <.icon name={:warning} class="mt-0.5 h-4 w-4 shrink-0 text-amber-600 dark:text-amber-500" />
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

    @doc "An inline error/warning banner."
    attr(:variant, :atom, default: :error)
    attr(:title, :string, required: true)
    slot(:inner_block)

    def error(assigns) do
      ~H"""
      <div class={["flex items-start gap-2.5 rounded-md border px-3 py-2.5", banner_class(@variant)]}>
        <.icon name={banner_icon(@variant)} class={["mt-0.5 h-4 w-4 shrink-0", banner_icon_color(@variant)]} />
        <div class={["text-[13px]", banner_text(@variant)]}>
          <div class="font-medium">{@title}</div>
          <div :if={@inner_block != []} class="opacity-90">{render_slot(@inner_block)}</div>
        </div>
      </div>
      """
    end

    @doc """
    The message composer: an auto-growing textarea with a send/stop control. Emits
    `phx-submit="send"` (text field `text`); when `streaming?` it shows a Stop button
    (`phx-click="cancel"`). Needs the `AgentixComposer` JS hook for Enter-to-send.
    """
    attr(:streaming?, :boolean, default: false)
    attr(:placeholder, :string, default: "Message the assistant…")

    def composer(assigns) do
      ~H"""
      <form phx-submit="send" class="rounded-xl border border-neutral-300 bg-white shadow-sm focus-within:border-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:focus-within:border-neutral-600">
        <textarea
          id="agentix-composer-input"
          name="text"
          rows="1"
          phx-hook="AgentixComposer"
          placeholder={@placeholder}
          class="block max-h-40 w-full resize-none bg-transparent px-3.5 py-3 text-[15px] leading-relaxed placeholder:text-neutral-400 focus:outline-none"
        ></textarea>
        <div class="flex items-center gap-2 px-2.5 pb-2.5">
          <span class="text-[12px] text-neutral-400">Enter to send · Shift+Enter for newline</span>
          <button
            :if={!@streaming?}
            type="submit"
            title="Send"
            class="ml-auto grid h-8 w-8 place-items-center rounded-md bg-neutral-900 text-neutral-50 transition hover:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-white"
          >
            <.icon name={:send} class="h-[18px] w-[18px]" />
          </button>
          <button
            :if={@streaming?}
            type="button"
            phx-click="cancel"
            class="ml-auto flex h-8 items-center gap-1.5 rounded-md border border-neutral-300 bg-white px-2.5 text-[13px] font-medium text-neutral-700 transition hover:bg-neutral-100 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200 dark:hover:bg-neutral-800"
          >
            <span class="h-2.5 w-2.5 rounded-[2px] bg-neutral-700 dark:bg-neutral-200"></span>Stop
          </button>
        </div>
      </form>
      """
    end

    @doc "The CSS for consecutive-row grouping and the reasoning chevron. Inline once."
    @spec css() :: String.t()
    def css do
      """
      /* Group consecutive same-role rows: drop the divider, hide the repeated avatar
         and header, and pull the row up so it reads as one block. */
      .agentix-thread > [data-role="assistant"] + [data-role="assistant"],
      .agentix-thread > [data-role="user"] + [data-role="user"] {
        border-top-color: transparent !important;
        padding-top: 0.25rem;
        margin-top: -0.75rem;
      }
      .agentix-thread > [data-role="assistant"] + [data-role="assistant"] > .agentix-avatar,
      .agentix-thread > [data-role="user"] + [data-role="user"] > .agentix-avatar {
        visibility: hidden;
      }
      .agentix-thread > [data-role="assistant"] + [data-role="assistant"] .agentix-role-header,
      .agentix-thread > [data-role="user"] + [data-role="user"] .agentix-role-header {
        display: none;
      }
      details[open] .agentix-chev { transform: rotate(90deg); }
      """
    end

    ## --- private ---

    attr(:role, :atom, required: true)

    defp role_header(assigns) do
      ~H"""
      <div class="agentix-role-header mb-1 flex items-center gap-2">
        <span class="text-[13px] font-semibold">{role_label(@role)}</span>
      </div>
      """
    end

    attr(:role, :atom, required: true)

    defp avatar(%{role: :user} = assigns) do
      ~H"""
      <div class="agentix-avatar mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-200 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300">
        <.icon name={:user} class="h-4 w-4" />
      </div>
      """
    end

    defp avatar(assigns) do
      ~H"""
      <div class="agentix-avatar mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-900 text-neutral-50 dark:bg-neutral-100 dark:text-neutral-900">
        <.icon name={:star} class="h-4 w-4" />
      </div>
      """
    end

    attr(:status, :atom, required: true)

    defp tool_icon(%{status: :ok} = assigns) do
      ~H"""
      <.icon name={:check} class="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-500" />
      """
    end

    defp tool_icon(%{status: :error} = assigns) do
      ~H"""
      <.icon name={:x} class="h-3.5 w-3.5 text-red-600 dark:text-red-500" />
      """
    end

    defp tool_icon(assigns) do
      ~H"""
      <.icon name={:spinner} class="h-3.5 w-3.5 animate-spin text-neutral-400" />
      """
    end

    attr(:name, :atom, required: true)
    attr(:class, :any, default: nil)

    defp icon(%{name: :star} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2l2.4 5.6L20 10l-5.6 2.4L12 18l-2.4-5.6L4 10l5.6-2.4z" /></svg>
      """
    end

    defp icon(%{name: :user} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 21a8 8 0 0 0-16 0" /><circle cx="12" cy="7" r="4" /></svg>
      """
    end

    defp icon(%{name: :spinner} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M21 12a9 9 0 1 1-6.2-8.5" stroke-linecap="round" /></svg>
      """
    end

    defp icon(%{name: :check} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M20 6L9 17l-5-5" /></svg>
      """
    end

    defp icon(%{name: :x} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M18 6 6 18M6 6l12 12" /></svg>
      """
    end

    defp icon(%{name: :warning} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 9v4M12 17h.01" /><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" /></svg>
      """
    end

    defp icon(%{name: :send} = assigns) do
      ~H"""
      <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M12 19V5M5 12l7-7 7 7" /></svg>
      """
    end

    defp tool_border(:error),
      do: "border-red-300/70 bg-red-50 dark:border-red-500/30 dark:bg-red-500/10"

    defp tool_border(_status), do: "border-neutral-200 dark:border-neutral-800"

    defp tool_text(:error), do: "text-red-700 dark:text-red-300"
    defp tool_text(_status), do: "text-neutral-700 dark:text-neutral-200"

    defp tool_meta(:error), do: "text-red-600/80 dark:text-red-400/80"
    defp tool_meta(_status), do: "text-neutral-400"

    defp tool_label(:running), do: "running"
    defp tool_label(:ok), do: "done"
    defp tool_label(:error), do: "error"

    defp banner_class(:warning),
      do: "border-amber-300/70 bg-amber-50 dark:border-amber-500/30 dark:bg-amber-500/10"

    defp banner_class(_variant),
      do: "border-red-300/70 bg-red-50 dark:border-red-500/30 dark:bg-red-500/10"

    defp banner_icon(:warning), do: :warning
    defp banner_icon(_variant), do: :warning
    defp banner_icon_color(:warning), do: "text-amber-600 dark:text-amber-500"
    defp banner_icon_color(_variant), do: "text-red-600 dark:text-red-500"
    defp banner_text(:warning), do: "text-amber-900 dark:text-amber-200"
    defp banner_text(_variant), do: "text-red-800 dark:text-red-200"

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
