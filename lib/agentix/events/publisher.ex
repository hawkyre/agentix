defmodule Agentix.Events.Publisher do
  @moduledoc """
  Builds and broadcasts the **live-event union** (the PubSub plane, D6).

  This module is the single declared home of the closed union of live events
  (contracts.md). The agent constructs nothing inline — it calls the typed helpers
  here, so Inc 6 (tools) and Inc 9 (LiveView) project against one source of truth.

  A `t:context/0` (built once per agent from its config via `new/2`) carries the
  resolved notifier module, the pub/sub name, and the conversation topic. Every
  helper takes that context and fires through `Agentix.Notifier`, which is lossy by
  contract — a dropped broadcast never affects the canonical log.

  Topic convention: `"agentix:conversation:<conversation_id>"`.
  """

  alias Agentix.Conversation.Config
  alias Agentix.Notifier

  @type context :: %{notifier: module(), pubsub: Notifier.pubsub(), topic: String.t()}

  @typedoc "The closed live-event union broadcast on a conversation topic."
  @type live_event ::
          {:state_changed, atom()}
          | {:turn_started, reference() | term()}
          | {:text_delta, term(), String.t(), String.t()}
          | {:thinking_delta, term(), String.t(), String.t()}
          | {:message_completed, term(), ReqLLM.Message.t()}
          | {:tool_call_started, String.t(), String.t(), atom(), map()}
          | {:tool_progress, String.t(), term()}
          | {:tool_call_resolved, String.t(), term()}
          | {:tool_call_errored, String.t(), term()}
          | {:suspended, String.t(), atom(), term()}
          | {:turn_completed, term()}
          | {:cancelled, term()}

  @doc "The pub/sub topic for a conversation."
  @spec topic(String.t()) :: String.t()
  def topic(conversation_id), do: "agentix:conversation:" <> conversation_id

  @doc """
  Builds the broadcast context for a conversation from its config, falling back to
  application-level configuration (then `Agentix.PubSub`) for an unset `pubsub`.
  """
  @spec new(Config.t(), String.t()) :: context()
  def new(%Config{} = config, conversation_id) do
    %{
      notifier: config.notifier || Notifier.impl(),
      pubsub: config.pubsub || Application.get_env(:agentix, :pubsub, Agentix.PubSub),
      topic: topic(conversation_id)
    }
  end

  @doc "Broadcasts a member of the live-event union on the conversation topic."
  @spec publish(context(), live_event()) :: :ok
  def publish(%{notifier: notifier, pubsub: pubsub, topic: topic}, event) do
    notifier.broadcast(pubsub, topic, event)
  end

  @doc "Broadcasts the FSM state the agent has just entered."
  @spec state_changed(context(), atom()) :: :ok
  def state_changed(ctx, state), do: publish(ctx, {:state_changed, state})

  @doc "Broadcasts that a new turn has begun."
  @spec turn_started(context(), term()) :: :ok
  def turn_started(ctx, turn_ref), do: publish(ctx, {:turn_started, turn_ref})

  @doc "Broadcasts an assistant text delta (→ the JS hook in the LiveView layer)."
  @spec text_delta(context(), term(), String.t(), String.t()) :: :ok
  def text_delta(ctx, turn_ref, msg_id, chunk),
    do: publish(ctx, {:text_delta, turn_ref, msg_id, chunk})

  @doc "Broadcasts a thinking/reasoning delta."
  @spec thinking_delta(context(), term(), String.t(), String.t()) :: :ok
  def thinking_delta(ctx, turn_ref, msg_id, chunk),
    do: publish(ctx, {:thinking_delta, turn_ref, msg_id, chunk})

  @doc "Broadcasts the finalized assistant message (→ stream_insert)."
  @spec message_completed(context(), term(), ReqLLM.Message.t()) :: :ok
  def message_completed(ctx, turn_ref, message),
    do: publish(ctx, {:message_completed, turn_ref, message})

  @doc "Broadcasts that a tool call has begun (dispatched or suspended)."
  @spec tool_call_started(context(), String.t(), String.t(), atom(), map()) :: :ok
  def tool_call_started(ctx, id, name, executor, args),
    do: publish(ctx, {:tool_call_started, id, name, executor, args})

  @doc "Broadcasts that a tool call resolved with a successful result."
  @spec tool_call_resolved(context(), String.t(), term()) :: :ok
  def tool_call_resolved(ctx, id, result), do: publish(ctx, {:tool_call_resolved, id, result})

  @doc "Broadcasts that a tool call resolved with an error."
  @spec tool_call_errored(context(), String.t(), term()) :: :ok
  def tool_call_errored(ctx, id, reason), do: publish(ctx, {:tool_call_errored, id, reason})

  @doc "Broadcasts that a tool call suspended, awaiting an external resolution."
  @spec suspended(context(), String.t(), atom(), term()) :: :ok
  def suspended(ctx, id, executor, prompt), do: publish(ctx, {:suspended, id, executor, prompt})

  @doc "Broadcasts that the turn completed normally."
  @spec turn_completed(context(), term()) :: :ok
  def turn_completed(ctx, turn_ref), do: publish(ctx, {:turn_completed, turn_ref})

  @doc "Broadcasts that the turn was cancelled."
  @spec cancelled(context(), term()) :: :ok
  def cancelled(ctx, turn_ref), do: publish(ctx, {:cancelled, turn_ref})
end
