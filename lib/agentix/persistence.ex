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

  @callback append_event(conversation_id(), Event.t()) :: {:ok, seq()} | {:error, term()}
  @callback stream_events(conversation_id(), keyword()) :: [Event.t()]
  @callback load_since(conversation_id()) :: {summary() | nil, [Event.t()]}
  @callback get_conversation(conversation_id()) :: conversation() | nil
  @callback put_conversation(conversation_id(), map()) :: :ok
  @callback put_fsm_state(conversation_id(), map()) :: :ok
  @callback upsert_tool_call(conversation_id(), tool_call()) :: :ok
  @callback get_tool_call(tool_call_id()) :: tool_call() | nil
  @callback pending_tool_calls(conversation_id()) :: [tool_call()]
  @callback resolve_tool_call(tool_call_id(), atom(), map() | nil) :: :ok | {:error, :stale}
  @callback latest_summary(conversation_id()) :: summary() | nil
  @callback put_summary(conversation_id(), summary()) :: :ok
  @callback schedule_expiry(conversation_id(), tool_call_id(), pos_integer()) :: :ok
  @callback cancel_expiry(conversation_id(), tool_call_id()) :: :ok
  @callback put_model_call(conversation_id(), model_call()) :: :ok
  @callback model_calls(conversation_id()) :: [model_call()]
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
