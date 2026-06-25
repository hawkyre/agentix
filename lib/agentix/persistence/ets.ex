defmodule Agentix.Persistence.ETS do
  @moduledoc """
  Ephemeral ETS persistence adapter — the default, no-database option.

  Reads and high-frequency single-writer-per-conversation writes (append,
  fsm_state, summaries) run directly against the named public tables owned by a
  dedicated owner process. Per-conversation `seq` is allocated atomically
  with `:ets.update_counter/4`. Tool-call resolution and suspension expiry — which
  may race across processes — are serialized through the owner.

  Does not survive a node restart (acceptable for the ephemeral adapter); the Ecto
  adapter is the durable option.
  """

  @behaviour Agentix.Persistence

  alias Agentix.Persistence.ETS.Owner

  @events :agentix_events
  @conversations :agentix_conversations
  @summaries :agentix_summaries
  @tool_calls :agentix_tool_calls
  @model_calls :agentix_model_calls

  @impl true
  def append_event(conversation_id, event) do
    seq =
      :ets.update_counter(
        @conversations,
        {:seq, conversation_id},
        {2, 1},
        {{:seq, conversation_id}, 0}
      )

    stored = %{
      event
      | conversation_id: conversation_id,
        seq: seq,
        inserted_at: event.inserted_at || DateTime.utc_now()
    }

    :ets.insert(@events, {{conversation_id, seq}, stored})
    {:ok, seq}
  end

  @impl true
  def stream_events(conversation_id, opts \\ []) do
    after_seq = Keyword.get(opts, :after, 0)
    guards = [{:>, :"$1", after_seq} | before_guard(opts)]

    events =
      @events
      |> :ets.select([{{{conversation_id, :"$1"}, :"$2"}, guards, [:"$2"]}])
      |> Enum.sort_by(& &1.seq)

    case Keyword.get(opts, :limit) do
      # `:limit` keeps the most-recent N within the range (the tail), still ascending.
      nil -> events
      limit -> Enum.take(events, -limit)
    end
  end

  defp before_guard(opts) do
    case Keyword.get(opts, :before) do
      nil -> []
      before -> [{:<, :"$1", before}]
    end
  end

  @impl true
  def load_since(conversation_id) do
    summary = latest_summary(conversation_id)
    after_seq = if summary, do: summary.to_seq, else: 0
    {summary, stream_events(conversation_id, after: after_seq)}
  end

  @impl true
  def get_conversation(conversation_id) do
    case :ets.lookup(@conversations, conversation_id) do
      [{^conversation_id, record}] -> record
      [] -> nil
    end
  end

  @impl true
  def put_conversation(conversation_id, attrs) do
    base =
      get_conversation(conversation_id) ||
        %{id: conversation_id, settings: %{}, status: :active, fsm_state: %{}}

    record = base |> Map.merge(Map.new(attrs)) |> Map.put(:id, conversation_id)
    :ets.insert(@conversations, {conversation_id, record})
    :ok
  end

  @impl true
  def put_fsm_state(conversation_id, fsm_state),
    do: put_conversation(conversation_id, %{fsm_state: fsm_state})

  @impl true
  def upsert_tool_call(conversation_id, tool_call) do
    record =
      tool_call
      |> Map.put(:conversation_id, conversation_id)
      |> Map.put_new(:status, :pending)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:resolved_at, nil)
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    :ets.insert(@tool_calls, {record.id, record})
    :ok
  end

  @impl true
  def get_tool_call(tool_call_id) do
    case :ets.lookup(@tool_calls, tool_call_id) do
      [{^tool_call_id, record}] -> record
      [] -> nil
    end
  end

  @impl true
  def pending_tool_calls(conversation_id) do
    :ets.select(@tool_calls, [
      {{:_, :"$1"},
       [
         {:andalso, {:==, {:map_get, :conversation_id, :"$1"}, conversation_id},
          {:==, {:map_get, :status, :"$1"}, :pending}}
       ], [:"$1"]}
    ])
  end

  @impl true
  def resolve_tool_call(tool_call_id, status, result),
    do: Owner.resolve(tool_call_id, status, result)

  @impl true
  def latest_summary(conversation_id) do
    case :ets.select(@summaries, [{{{conversation_id, :"$1"}, :"$2"}, [], [:"$2"]}]) do
      [] -> nil
      summaries -> Enum.max_by(summaries, & &1.to_seq)
    end
  end

  @impl true
  def put_summary(conversation_id, summary) do
    record =
      summary
      |> Map.put(:conversation_id, conversation_id)
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    :ets.insert(@summaries, {{conversation_id, record.to_seq}, record})
    :ok
  end

  @impl true
  def schedule_expiry(conversation_id, tool_call_id, timeout_ms),
    do: Owner.schedule_expiry(conversation_id, tool_call_id, timeout_ms)

  @impl true
  def cancel_expiry(conversation_id, tool_call_id),
    do: Owner.cancel_expiry(conversation_id, tool_call_id)

  @impl true
  def put_model_call(conversation_id, model_call) do
    if audit_enabled?() do
      record =
        model_call
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put_new(:inserted_at, DateTime.utc_now())

      :ets.insert(@model_calls, {{conversation_id, record.turn_ref}, record})
    end

    :ok
  end

  @impl true
  def model_calls(conversation_id) do
    @model_calls
    |> :ets.select([{{{conversation_id, :"$1"}, :"$2"}, [], [:"$2"]}])
    |> Enum.sort_by(& &1.turn_ref)
  end

  @impl true
  def gc_model_calls(conversation_id, ttl_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_ms, :millisecond)

    {stale, _fresh} =
      conversation_id
      |> model_calls()
      |> Enum.split_with(fn model_call -> not DateTime.after?(model_call.inserted_at, cutoff) end)

    Enum.each(stale, fn model_call ->
      :ets.delete(@model_calls, {conversation_id, model_call.turn_ref})
    end)

    {:ok, length(stale)}
  end

  defp audit_enabled?, do: Application.get_env(:agentix, :audit, false)
end
