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

      <div id="agentix-scroll" phx-hook="AgentixAutoScroll" class="flex-1">
        <.message_list
          messages={@streams.messages}
          streaming_message={@streaming_message}
          in_flight_tools={@in_flight_tools}
          pending={@pending}
          assistant_open={@agentix_assistant_open}
        />
      </div>

      <div class="sticky bottom-0 border-t border-neutral-200/70 bg-neutral-50/90 pb-5 pt-3 backdrop-blur dark:border-neutral-800/70 dark:bg-neutral-950/90">
        <.composer streaming?={@streaming?} placeholder="Ask about the Agentix source…" />
      </div>
    </.app_shell>
    """
  end

  attr :offline?, :boolean, required: true

  defp intro(assigns) do
    ~H"""
    <div class="mt-4 rounded-lg border border-neutral-200 bg-white/60 px-4 py-3 text-sm text-neutral-600 dark:border-neutral-800 dark:bg-neutral-900/40 dark:text-neutral-300">
      <p class="font-medium text-neutral-900 dark:text-neutral-100">
        Agentix, meet Agentix — ask the assistant about its own source
      </p>
      <p class="mt-1">
        Claude really reads this library's code to answer. It'll
        <span class="font-medium">search</span>
        the source, <span class="font-medium">read</span>
        files, and — with your approval — <span class="font-medium">run a test file</span>.
        Try: <em>"How does durable suspension work?"</em>, <em>"Where's the compaction
        pipeline?"</em>, or <em>"Run the hook tests."</em>
      </p>
      <p :if={@offline?} class="mt-1 text-amber-700 dark:text-amber-400">
        No <code>ANTHROPIC_API_KEY</code> set — running on the offline provider (canned replies).
        Set the key and restart for the real thing.
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

  @system_prompt """
  You are the Agentix Assistant, embedded in the demo app of the Agentix library — and your
  job is to answer questions about Agentix *by reading its own source code*. Agentix is a
  LiveView-native agent runtime for Elixir, built on ReqLLM (one `:gen_statem` per
  conversation, an executor-based tool/HITL model, a hook pipeline, reducer compaction, and
  pluggable ETS/Ecto persistence).

  Always ground your answers in the real code — don't guess:
    1. Use `search_code` to find where something lives (returns file:line matches).
    2. Use `read_file` to read the relevant module or guide.
    3. Explain concisely and cite the real file paths you read.

  When the user wants to verify behavior, you may call `run_tests` with a specific test file
  (e.g. test/agentix/hook_test.exs) — that asks the user to approve running it. Prefer reading
  source for "how does X work" questions; only run tests when asked to check that something works.
  Keep replies tight and concrete; quote short snippets, not whole files.
  """

  defp config do
    # Real tools over the Agentix repo — two read-only (`:server`, run inline) and one
    # approval-gated action (`:server` + `:requires_approval`) so the HITL gate guards a
    # genuinely consequential operation (spawning the test suite).
    search =
      Tool.new(
        name: "search_code",
        description:
          "Search the Agentix source (lib/ + guides/) for a string or symbol. Returns file:line matches. Use this first to locate where something is implemented.",
        executor: :server,
        parameter_schema: [
          query: [type: :string, required: true, doc: "text or symbol to grep for"]
        ],
        callback: fn args, _turn -> {:ok, AgentixDemo.RepoTools.search_code(arg(args, "query"))} end
      )

    read =
      Tool.new(
        name: "read_file",
        description:
          "Read a file from the Agentix repo by path relative to the repo root (e.g. lib/agentix/hook.ex or guides/tools.md).",
        executor: :server,
        parameter_schema: [
          path: [type: :string, required: true, doc: "repo-relative file path"]
        ],
        callback: fn args, _turn -> {:ok, AgentixDemo.RepoTools.read_file(arg(args, "path"))} end
      )

    run_tests =
      Tool.new(
        name: "run_tests",
        description:
          "Run a single Agentix test file (e.g. test/agentix/hook_test.exs) to verify behavior. Requires the user's approval before it runs.",
        executor: :server,
        approval: :requires_approval,
        parameter_schema: [
          path: [type: :string, required: true, doc: "path to a *_test.exs file under test/"]
        ],
        callback: fn args, _turn -> {:ok, AgentixDemo.RepoTools.run_tests(arg(args, "path"))} end
      )

    Config.new(
      model: ModelConfig.model(),
      system_prompt: @system_prompt,
      tools: [search, read, run_tests]
    )
  end

  defp arg(args, key), do: args[key] || args[String.to_existing_atom(key)] || ""
end
