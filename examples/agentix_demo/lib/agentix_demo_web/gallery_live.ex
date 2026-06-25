defmodule AgentixDemoWeb.GalleryLive do
  @moduledoc """
  A static storybook of every Agentix component in every state — messages, the reasoning
  panel, tool rows (running/ok/error + the result inspector), the approval and elicitation
  pending controls, error/warning banners, and the composer. Useful for theming and for
  seeing what the headless layer renders without driving a live conversation.
  """
  use Phoenix.LiveView

  import AgentixDemoWeb.AgentixComponents
  import AgentixDemoWeb.Shell

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @impl Phoenix.LiveView
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(:theme, "light") |> assign(:streaming?, false)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.app_shell theme={@theme} active={:gallery}>
      <div class="space-y-7 py-8">
        <div>
          <h1 class="text-[19px] font-semibold tracking-tight">Component states</h1>
          <p class="mt-1 text-[13px] text-neutral-500 dark:text-neutral-400">
            Every component, isolated. Toggle the theme in the top bar.
          </p>
        </div>

        <.card title="Messages" desc="one turn · text + tool + text, single header">
          <div class="agentix-thread">
            <.message id="g-u1" message={msg(:user, "How do I paginate a LiveView stream?")} />
            <.message id="g-a1" message={msg(:assistant, "Let me check the docs.")} />
            <.message id="g-t1" message={tool_msg("t-doc", "search_docs", :ok)} />
            <.message
              id="g-a2"
              message={msg(:assistant, "Use stream/4 with a cursor and append on phx-viewport-bottom.")}
            />
          </div>
        </.card>

        <.card title="Reasoning" desc="collapsible thinking panel">
          <.reasoning label="Thought for 4s">
            Two approaches: offset vs cursor pagination. Cursor avoids skips when rows shift,
            so I'll recommend that.
          </.reasoning>
        </.card>

        <.card title="Tool calls" desc="running · ok · error · result inspector">
          <.tool id="g-r1" name="web_search" status={:running} meta="querying…" />
          <.tool id="g-r2" name="read_file" status={:ok} meta="412 rows · 38ms" />
          <.tool id="g-r3" name="get_weather" status={:ok} result="It's 21°C and sunny in Tokyo." />
          <.tool id="g-r4" name="run_tests" status={:error} meta="2 failed" />
        </.card>

        <.card title="Permission" desc="approval">
          <.pending id="g-p1" entry={%{executor: :server, kind: :approval, prompt: %{}}} />
        </.card>

        <.card title="Elicitation" desc="awaiting input">
          <.pending id="g-p2" entry={%{executor: :human, kind: :elicitation, prompt: %{}}} />
        </.card>

        <.card title="Errors" desc="error · warning">
          <.error title="Couldn't reach the model.">Connection lost. Retry in a moment.</.error>
          <.error variant={:warning} title="Rate limit reached.">Try again in 30s.</.error>
        </.card>

        <.card title="Composer" desc="auto-grow · Enter to send">
          <.composer />
        </.card>
      </div>
    </.app_shell>
    """
  end

  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900">
      <div class="flex items-baseline justify-between border-b border-neutral-100 px-4 py-2.5 dark:border-neutral-800">
        <h2 class="text-[13px] font-semibold">{@title}</h2>
        <span class="text-[12px] text-neutral-400">{@desc}</span>
      </div>
      <div class="space-y-3 px-4 py-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_theme", _params, socket) do
    next = if socket.assigns.theme == "dark", do: "light", else: "dark"
    {:noreply, socket |> assign(:theme, next) |> push_event("set-theme", %{theme: next})}
  end

  def handle_event("theme-restored", %{"theme" => theme}, socket) when theme in ["light", "dark"],
    do: {:noreply, assign(socket, :theme, theme)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp msg(role, text), do: %Message{role: role, content: [ContentPart.text(text)]}

  defp tool_msg(id, name, status) do
    %Message{
      role: :tool,
      tool_call_id: id,
      content: [ContentPart.text(~s({"ok":true}))],
      metadata: %{"tool_name" => name, "tool_status" => to_string(status)}
    }
  end
end
