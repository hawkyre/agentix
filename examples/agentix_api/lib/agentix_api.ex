defmodule AgentixApi do
  @moduledoc """
  A Tier-1 (headless / API-only) Agentix consumer — no LiveView, no database.

  Agentix needs no web framework to run: `Agentix.Application` boots its own registry,
  task supervisor, ETS persistence, and `Phoenix.PubSub` (the live-event backbone). A host
  drives conversations through `Agentix.Conversation.*` and streams output to clients off
  the **live-event union** over any transport it writes (SSE, channel, JSON polling).

  This module is a thin demonstration wrapper: start a conversation, subscribe to its live
  events, send a message, and accumulate the streamed assistant reply from the event plane.
  """

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope

  @doc "Starts (or revives) a conversation. `opts` are `Agentix.Conversation.Config` fields."
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(conversation_id, opts \\ []) do
    Conversation.ensure_started(conversation_id, config: Config.new(opts))
  end

  @doc "Subscribes the caller to the conversation's live-event topic on Agentix's PubSub."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(conversation_id))
  end

  @doc "Sends a user message into the conversation under an anonymous scope."
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  def send_message(conversation_id, text) do
    Conversation.send_message(conversation_id, text, Scope.new())
  end

  @doc """
  Blocks collecting streamed assistant text off the live-event plane until the turn
  completes (or `timeout` elapses). The caller must have `subscribe/1`'d first. Returns the
  concatenated text — exactly what an SSE/channel transport would forward token by token.
  """
  @spec collect_reply(timeout()) :: String.t()
  def collect_reply(timeout \\ 5_000), do: collect_reply("", timeout)

  defp collect_reply(acc, timeout) do
    receive do
      {:text_delta, _turn_ref, _msg_id, chunk, _seq} -> collect_reply(acc <> chunk, timeout)
      {:turn_completed, _turn_ref} -> acc
      {:cancelled, _turn_ref} -> acc
    after
      timeout -> acc
    end
  end
end
