defmodule AgentixDemoWeb.ChatLive do
  @moduledoc """
  The Tier-3 chat surface: `use Agentix.Chat` projects the conversation onto assigns and the
  generated `AgentixDemoWeb.AgentixComponents` render them. A `:human` tool (`ask_user`)
  exercises the HITL elicitation flow — the assistant suspends for an answer, the user
  submits it through the pending form, and the turn resumes.
  """
  use Phoenix.LiveView
  use Agentix.Chat

  import AgentixDemoWeb.AgentixComponents

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Tool

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    id =
      session["conversation_id"] || "demo-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _pid} = Conversation.ensure_started(id, config: config())
    # `attach_conversation` seeds the projection assigns; `:agentix_error` is only set when a
    # send fails, so seed it to nil for the initial render of the error banner.
    {:ok, socket |> attach_conversation(id) |> assign(:agentix_error, nil)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col py-2">
      <.error :if={@agentix_error} title={"Couldn't send: #{inspect(@agentix_error)}"} />

      <div class="flex-1">
        <.message_list
          messages={@streams.messages}
          streaming_message={@streaming_message}
          in_flight_tools={@in_flight_tools}
          pending={@pending}
          assistant_open={@agentix_assistant_open}
        />
      </div>

      <div class="sticky bottom-0 border-t border-neutral-200/70 bg-neutral-50/90 pb-5 pt-3 backdrop-blur">
        <.composer streaming?={@streaming?} placeholder="Message the assistant…" />
      </div>
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

  # Talks to Anthropic Claude Haiku via ReqLLM — export ANTHROPIC_API_KEY before
  # `mix phx.server`. The test suite installs the mock provider, so the model string is
  # irrelevant there.
  defp config do
    ask_user =
      Tool.new(
        name: "ask_user",
        description: "Ask the user a clarifying question before continuing.",
        executor: :human
      )

    Config.new(model: "anthropic:claude-haiku-4-5", tools: [ask_user])
  end
end
