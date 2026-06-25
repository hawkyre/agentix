defmodule AgentixDemoWeb.ChatLive do
  @moduledoc """
  The Tier-3 chat surface: `use Agentix.Chat` projects the conversation onto assigns and the
  generated `AgentixDemoWeb.AgentixComponents` render them.

  The conversation id lives in the URL (`/c/:id`) so a page reload reattaches to the same
  conversation and its history is reloaded from Postgres. With no `ANTHROPIC_API_KEY` the demo
  runs on `AgentixDemo.OfflineProvider`; set the key for real Claude responses. A `:human` tool
  (`ask_user`) exercises the HITL elicitation flow.
  """
  use Phoenix.LiveView
  use Agentix.Chat

  import AgentixDemoWeb.AgentixComponents
  import AgentixDemoWeb.Shell

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Tool
  alias AgentixDemo.ModelConfig

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok, _pid} = Conversation.ensure_started(id, config: config())

    socket =
      socket
      |> assign(:conversation_id, id)
      |> assign(:theme, "light")
      |> assign(:agentix_error, nil)
      |> attach_conversation(id)

    {:ok, socket}
  end

  # `/` — mint a fresh conversation id and move to its canonical URL so reloads are stable.
  def mount(_params, _session, socket) do
    id = "demo-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, push_navigate(socket, to: "/c/" <> id)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.app_shell theme={@theme} active={:chat}>
      <.intro offline?={ModelConfig.offline?()} />

      <div :if={@agentix_error} class="relative mt-3">
        <.error title={"Couldn't send: #{inspect(@agentix_error)}"} />
        <button
          phx-click="dismiss_error"
          class="absolute right-3 top-3 text-xs font-medium text-red-700 underline dark:text-red-300"
        >
          Dismiss
        </button>
      </div>

      <div class="flex-1">
        <.message_list
          messages={@streams.messages}
          streaming_message={@streaming_message}
          in_flight_tools={@in_flight_tools}
          pending={@pending}
          assistant_open={@agentix_assistant_open}
        />
      </div>

      <div class="sticky bottom-0 border-t border-neutral-200/70 bg-neutral-50/90 pb-5 pt-3 backdrop-blur dark:border-neutral-800/70 dark:bg-neutral-950/90">
        <.composer streaming?={@streaming?} placeholder="Message the assistant…" />
      </div>
    </.app_shell>
    """
  end

  attr :offline?, :boolean, required: true

  defp intro(assigns) do
    ~H"""
    <div class="mt-4 rounded-lg border border-neutral-200 bg-white/60 px-4 py-3 text-sm text-neutral-600 dark:border-neutral-800 dark:bg-neutral-900/40 dark:text-neutral-300">
      <p class="font-medium text-neutral-900 dark:text-neutral-100">Agentix chat demo</p>
      <p class="mt-1">
        Send a message to stream a reply. The assistant can ask you a clarifying question
        (human-in-the-loop) — answer it inline to resume the turn.
      </p>
      <p :if={@offline?} class="mt-1 text-amber-700 dark:text-amber-400">
        Running on the offline provider (no <code>ANTHROPIC_API_KEY</code>). Replies are canned;
        set the key and restart for real Claude responses.
      </p>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("send", %{"text" => text}, socket), do: {:noreply, send_message(socket, text)}

  def handle_event("approve", %{"id" => id}, socket), do: {:noreply, resolve(socket, id, :approve)}

  def handle_event("deny", %{"id" => id}, socket),
    do: {:noreply, resolve(socket, id, %{approved: false})}

  def handle_event("resolve", %{"tool_call_id" => id} = params, socket),
    do: {:noreply, resolve(socket, id, params["answer"] || params["result"])}

  def handle_event("cancel", _params, socket), do: {:noreply, cancel(socket)}

  def handle_event("dismiss_error", _params, socket),
    do: {:noreply, assign(socket, :agentix_error, nil)}

  def handle_event("toggle_theme", _params, socket) do
    next = if socket.assigns.theme == "dark", do: "light", else: "dark"
    {:noreply, socket |> assign(:theme, next) |> push_event("set-theme", %{theme: next})}
  end

  # The Theme JS hook reports the persisted theme on connect, so the toggle icon matches.
  def handle_event("theme-restored", %{"theme" => theme}, socket) when theme in ["light", "dark"],
    do: {:noreply, assign(socket, :theme, theme)}

  # Ignore any out-of-range value (corrupt localStorage / a direct socket message) — never crash.
  def handle_event("theme-restored", _params, socket), do: {:noreply, socket}

  defp config do
    # Three executors so the demo exercises every tool path:
    #   * :server + :requires_approval  → runs your code, but gated behind approve/deny
    #   * :server (non-gated)           → runs your code inline
    #   * :human                        → suspends for a person's answer (elicitation)
    weather =
      Tool.new(
        name: "get_weather",
        description: "Look up the current weather for a city. Requires approval.",
        executor: :server,
        approval: :requires_approval,
        callback: fn args, _turn ->
          city = args["city"] || args[:city] || "your area"
          {:ok, "It's 21°C and sunny in #{city}."}
        end
      )

    calculator =
      Tool.new(
        name: "calculator",
        description: "Evaluate a simple arithmetic expression like '6 * 7'.",
        executor: :server,
        callback: fn args, _turn ->
          expr = args["expression"] || args[:expression] || ""
          {:ok, AgentixDemo.Calc.eval(expr)}
        end
      )

    ask_user =
      Tool.new(
        name: "ask_user",
        description: "Ask the user a clarifying question before continuing.",
        executor: :human
      )

    Config.new(model: ModelConfig.model(), tools: [weather, calculator, ask_user])
  end
end
