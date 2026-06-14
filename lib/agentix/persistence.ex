defmodule Agentix.Persistence do
  @moduledoc """
  The persistence behaviour and a thin dispatch to the configured adapter.

  An append-only, ordered `events` log is the source of truth; everything else is
  a cache or a derived artifact. Two adapters ship: `Agentix.Persistence.ETS`
  (default, ephemeral) and, later, an Ecto/Postgres adapter. Both must pass the
  shared `Agentix.PersistenceConformance` suite, so callers cannot tell them apart.

  Records crossing this boundary are plain maps (and `Agentix.Event` structs),
  never adapter-specific structs, so the core never depends on Ecto.

  ## Record shapes

    * **conversation** — `%{id, settings, status, fsm_state}`.
    * **fsm_state** — `%{state, pending, last_seq}` (a cache over the log).
    * **summary** — `%{from_seq, to_seq, content, version}` (+ adapter-assigned id/inserted_at).
    * **tool_call** — `%{id, conversation_id, executor, status, args, result, ...}`.
    * **model_call** — `%{turn_ref, rendered_context, model, usage, ...}` (audit, off by default).

  Configure with `config :agentix, :persistence, Agentix.Persistence.ETS` (or
  `{module, opts}`).
  """

  alias Agentix.Event

  @type conversation_id :: String.t()
  @type tool_call_id :: String.t()
  @type seq :: non_neg_integer()
  @type conversation :: %{
          id: conversation_id(),
          settings: map(),
          status: atom(),
          fsm_state: map()
        }
  @type summary :: map()
  @type tool_call :: map()
  @type model_call :: map()

  @doc """
  Appends `event` to the conversation log, assigning the next per-conversation
  `seq` (monotonic, 1-based). Returns the assigned `seq`. Implementations must keep
  `seq` strictly increasing per conversation; concurrent appends to the *same*
  conversation are not expected (one agent writes per conversation).
  """
  @callback append_event(conversation_id(), Event.t()) :: {:ok, seq()} | {:error, term()}

  @doc """
  Returns the conversation's events ordered by ascending `seq`. Options: `:after`
  (exclusive `seq` lower bound, default 0) and `:limit` (max events).
  """
  @callback stream_events(conversation_id(), keyword()) :: [Event.t()]

  @doc """
  Revival read: returns `{latest_summary_or_nil, events_after_that_summary}`. With
  no summary, returns `{nil, all_events}`. This is how a revived agent rebuilds its
  working set without replaying from `seq` 1.
  """
  @callback load_since(conversation_id()) :: {summary() | nil, [Event.t()]}

  @doc "Returns the conversation record (`%{id, settings, status, fsm_state}`) or `nil`."
  @callback get_conversation(conversation_id()) :: conversation() | nil

  @doc "Upserts the conversation record, merging `attrs` (`:settings`, `:status`, `:fsm_state`)."
  @callback put_conversation(conversation_id(), map()) :: :ok

  @doc """
  Upserts just the `fsm_state` cache (`%{state, pending, last_seq}`), creating the
  conversation row if absent. `fsm_state` is a cache over the log, never the source
  of truth.
  """
  @callback put_fsm_state(conversation_id(), map()) :: :ok

  @doc """
  Inserts or replaces a tool-call record (keyed by its `tool_call_id`). Used to
  track HITL suspensions so they survive a kill. New records default to
  `status: :pending`.
  """
  @callback upsert_tool_call(conversation_id(), tool_call()) :: :ok

  @doc "Returns the tool-call record for `tool_call_id`, or `nil`."
  @callback get_tool_call(tool_call_id()) :: tool_call() | nil

  @doc "Returns the conversation's tool calls currently in `:pending` status."
  @callback pending_tool_calls(conversation_id()) :: [tool_call()]

  @doc """
  Atomically resolves a tool call **only if it is currently `:pending`**, setting
  its `status` and `result`. Returns `{:error, :stale}` if the id is unknown or
  already resolved/expired — this is what makes double-clicks, resubmits, and the
  kill→revive→late-answer race safe. Implementations must guarantee atomicity
  against concurrent resolvers.
  """
  @callback resolve_tool_call(tool_call_id(), atom(), map() | nil) :: :ok | {:error, :stale}

  @doc "Returns the summary with the greatest `to_seq` for the conversation, or `nil`."
  @callback latest_summary(conversation_id()) :: summary() | nil

  @doc "Stores a derived compaction summary (keyed by its `to_seq`)."
  @callback put_summary(conversation_id(), summary()) :: :ok

  @doc """
  Schedules `tool_call_id` to be resolved to a tool-error after `timeout_ms` if it
  is still pending. Owned by the adapter (not a per-agent timer) so it survives the
  agent being killed. Rescheduling the same call replaces the prior timer.
  """
  @callback schedule_expiry(conversation_id(), tool_call_id(), pos_integer()) :: :ok

  @doc "Cancels a pending expiry scheduled by `schedule_expiry/3`."
  @callback cancel_expiry(conversation_id(), tool_call_id()) :: :ok

  @doc """
  Records a `model_call` audit row (exactly what was rendered to the model that
  turn). **A no-op unless the audit flag is enabled** (`config :agentix, :audit`).
  """
  @callback put_model_call(conversation_id(), model_call()) :: :ok

  @doc "Returns the conversation's audit rows ordered by `turn_ref` (empty when audit is off)."
  @callback model_calls(conversation_id()) :: [model_call()]

  @doc """
  Deletes audit rows older than `ttl_ms` (relative to now) for the conversation,
  returning the count removed. Used for TTL-based GC of the audit table.
  """
  @callback gc_model_calls(conversation_id(), non_neg_integer()) :: {:ok, non_neg_integer()}

  @default_adapter Agentix.Persistence.ETS

  @doc "The configured persistence adapter module."
  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:agentix, :persistence, @default_adapter) do
      {module, _opts} -> module
      module when is_atom(module) -> module
    end
  end

  @spec append_event(conversation_id(), Event.t()) :: {:ok, seq()} | {:error, term()}
  def append_event(conversation_id, event), do: adapter().append_event(conversation_id, event)

  @spec stream_events(conversation_id(), keyword()) :: [Event.t()]
  def stream_events(conversation_id, opts \\ []), do: adapter().stream_events(conversation_id, opts)

  @spec load_since(conversation_id()) :: {summary() | nil, [Event.t()]}
  def load_since(conversation_id), do: adapter().load_since(conversation_id)

  @spec get_conversation(conversation_id()) :: conversation() | nil
  def get_conversation(conversation_id), do: adapter().get_conversation(conversation_id)

  @spec put_conversation(conversation_id(), map()) :: :ok
  def put_conversation(conversation_id, attrs),
    do: adapter().put_conversation(conversation_id, attrs)

  @spec put_fsm_state(conversation_id(), map()) :: :ok
  def put_fsm_state(conversation_id, fsm_state),
    do: adapter().put_fsm_state(conversation_id, fsm_state)

  @spec upsert_tool_call(conversation_id(), tool_call()) :: :ok
  def upsert_tool_call(conversation_id, tool_call),
    do: adapter().upsert_tool_call(conversation_id, tool_call)

  @spec get_tool_call(tool_call_id()) :: tool_call() | nil
  def get_tool_call(tool_call_id), do: adapter().get_tool_call(tool_call_id)

  @spec pending_tool_calls(conversation_id()) :: [tool_call()]
  def pending_tool_calls(conversation_id), do: adapter().pending_tool_calls(conversation_id)

  @spec resolve_tool_call(tool_call_id(), atom(), map() | nil) :: :ok | {:error, :stale}
  def resolve_tool_call(tool_call_id, status, result),
    do: adapter().resolve_tool_call(tool_call_id, status, result)

  @spec latest_summary(conversation_id()) :: summary() | nil
  def latest_summary(conversation_id), do: adapter().latest_summary(conversation_id)

  @spec put_summary(conversation_id(), summary()) :: :ok
  def put_summary(conversation_id, summary), do: adapter().put_summary(conversation_id, summary)

  @spec schedule_expiry(conversation_id(), tool_call_id(), pos_integer()) :: :ok
  def schedule_expiry(conversation_id, tool_call_id, timeout_ms),
    do: adapter().schedule_expiry(conversation_id, tool_call_id, timeout_ms)

  @spec cancel_expiry(conversation_id(), tool_call_id()) :: :ok
  def cancel_expiry(conversation_id, tool_call_id),
    do: adapter().cancel_expiry(conversation_id, tool_call_id)

  @spec put_model_call(conversation_id(), model_call()) :: :ok
  def put_model_call(conversation_id, model_call),
    do: adapter().put_model_call(conversation_id, model_call)

  @spec model_calls(conversation_id()) :: [model_call()]
  def model_calls(conversation_id), do: adapter().model_calls(conversation_id)

  @spec gc_model_calls(conversation_id(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def gc_model_calls(conversation_id, ttl_ms), do: adapter().gc_model_calls(conversation_id, ttl_ms)
end
