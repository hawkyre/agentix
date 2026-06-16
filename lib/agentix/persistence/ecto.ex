if Code.ensure_loaded?(Ecto) do
  defmodule Agentix.Persistence.Ecto do
    @moduledoc """
    Durable Ecto/Postgres persistence adapter — the opt-in alternative to the default
    ephemeral `Agentix.Persistence.ETS`. Passes the same `Agentix.PersistenceConformance`
    suite, so callers cannot tell the two apart.

    ## Wiring

        config :agentix, :persistence, {Agentix.Persistence.Ecto, repo: MyApp.Repo}

    The host owns the `Repo` and runs the migration (`mix agentix.gen.migration`, then
    `mix ecto.migrate`). `Agentix.Persistence.adapter/0` drops the opts, so the adapter
    reads its `:repo` straight from the application env.

    ## jsonb key form

    Postgres `jsonb` round-trips as **string-keyed** maps. The ETS adapter keeps the
    atom-keyed maps it is handed, and the conformance suite pins an atom form for the two
    places Agentix semantically needs atoms — a tool `result` (`%{ok: …}`) and the
    `fsm_state` cache. This adapter decodes exactly those known shapes back to atoms on
    read; free-form blobs (`event.content`, tool `args`, summary `content`, conversation
    `settings`) stay string-keyed, which is their canonical persisted form (Codec output).

    ## Expiry

    `schedule_expiry/3` / `cancel_expiry/2` are backed by Oban, so a scheduled expiry lives
    in the database and survives the agent being killed (a per-agent timer would not). Oban
    is an **optional dependency of this adapter only**; every Oban reference is guarded, and
    calling these without `:oban` raises.

    > Note: the agent currently arms suspension timeouts with an in-process timer
    > (`Agentix.Agent`); delegating that lifecycle to `schedule_expiry/3` so a *revived*
    > agent's pending calls keep their timeout is a separate integration (see the Inc 11
    > carry-forward in `.plans/`).
    """

    @behaviour Agentix.Persistence

    import Ecto.Query

    alias Agentix.Event
    alias Agentix.Persistence.Ecto.Conversation
    alias Agentix.Persistence.Ecto.Event, as: EventSchema
    alias Agentix.Persistence.Ecto.ExpiryWorker
    alias Agentix.Persistence.Ecto.ModelCall
    alias Agentix.Persistence.Ecto.Summary
    alias Agentix.Persistence.Ecto.ToolCall

    @events_unique "agentix_events_conversation_id_seq_index"

    @impl true
    def append_event(conversation_id, %Event{} = event) do
      ensure_conversation(conversation_id)

      attrs = %{
        conversation_id: conversation_id,
        seq: next_seq(conversation_id),
        type: event.type,
        content: event.content,
        inserted_at: event.inserted_at || DateTime.utc_now()
      }

      %EventSchema{}
      |> Ecto.Changeset.cast(attrs, [:conversation_id, :seq, :type, :content, :inserted_at])
      |> Ecto.Changeset.unique_constraint(:seq, name: @events_unique)
      |> repo().insert()
      |> case do
        {:ok, row} -> {:ok, row.seq}
        # The Registry single-writer invariant should make this unreachable; surface it
        # loudly rather than corrupt the ordered log.
        {:error, _changeset} -> {:error, :seq_conflict}
      end
    end

    # Events/summaries/tool_calls/model_calls FK to conversations. The conformance suite
    # (and any caller) may write them before a conversation row exists, so create a minimal
    # one on demand — the FK stays for cascade-delete integrity, matching ETS's tolerance.
    defp ensure_conversation(conversation_id) do
      repo().insert(%Conversation{id: conversation_id}, on_conflict: :nothing, conflict_target: :id)
    end

    defp next_seq(conversation_id) do
      max =
        repo().one(
          from(e in EventSchema, where: e.conversation_id == ^conversation_id, select: max(e.seq))
        )

      (max || 0) + 1
    end

    @impl true
    def stream_events(conversation_id, opts \\ []) do
      after_seq = Keyword.get(opts, :after, 0)

      base =
        from(e in EventSchema,
          where: e.conversation_id == ^conversation_id and e.seq > ^after_seq
        )

      base = before_filter(base, Keyword.get(opts, :before))

      case Keyword.get(opts, :limit) do
        nil ->
          base |> order_by([e], asc: e.seq) |> repo().all() |> Enum.map(&to_event/1)

        limit ->
          # The most-recent N within the range (tail), returned ascending.
          base
          |> order_by([e], desc: e.seq)
          |> limit(^limit)
          |> repo().all()
          |> Enum.reverse()
          |> Enum.map(&to_event/1)
      end
    end

    defp before_filter(query, nil), do: query
    defp before_filter(query, before), do: from(e in query, where: e.seq < ^before)

    @impl true
    def load_since(conversation_id) do
      summary = latest_summary(conversation_id)
      after_seq = if summary, do: summary.to_seq, else: 0
      {summary, stream_events(conversation_id, after: after_seq)}
    end

    @impl true
    def get_conversation(conversation_id) do
      case repo().get(Conversation, conversation_id) do
        nil ->
          nil

        row ->
          %{
            id: row.id,
            settings: row.settings,
            status: row.status,
            fsm_state: decode_fsm_state(row.fsm_state)
          }
      end
    end

    @impl true
    def put_conversation(conversation_id, attrs) do
      attrs = Map.new(attrs)
      base = repo().get(Conversation, conversation_id) || %Conversation{id: conversation_id}

      base
      |> Ecto.Changeset.change(%{
        settings: sanitize_settings(Map.get(attrs, :settings, base.settings || %{})),
        fsm_state: Map.get(attrs, :fsm_state, base.fsm_state || %{}),
        status: Map.get(attrs, :status, base.status || :active)
      })
      |> repo().insert_or_update!()

      :ok
    end

    # Config settings carry functions/structs (`tools`, `hooks`, `stream_transformer`) and
    # runtime wiring (`persistence`, `notifier`, `pubsub`) that have no JSON form. Drop them
    # before the jsonb write; the host re-registers them at `ensure_started` (the ETS adapter
    # keeps them verbatim, so this trimming is Ecto-only).
    @nonserializable_settings ~w(tools hooks stream_transformer persistence notifier pubsub)
    @nonserializable_keys @nonserializable_settings ++
                            Enum.map(@nonserializable_settings, &String.to_atom/1)

    defp sanitize_settings(settings) when is_map(settings),
      do: Map.drop(settings, @nonserializable_keys)

    defp sanitize_settings(settings), do: settings

    @impl true
    def put_fsm_state(conversation_id, fsm_state),
      do: put_conversation(conversation_id, %{fsm_state: fsm_state})

    @impl true
    def upsert_tool_call(conversation_id, tool_call) do
      ensure_conversation(conversation_id)

      attrs =
        tool_call
        |> Map.new()
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put_new(:status, :pending)
        |> Map.put_new(:inserted_at, DateTime.utc_now())

      %ToolCall{}
      |> Ecto.Changeset.cast(attrs, [
        :id,
        :conversation_id,
        :name,
        :executor,
        :status,
        :args,
        :result,
        :inserted_at,
        :resolved_at
      ])
      |> repo().insert!(on_conflict: :replace_all, conflict_target: :id)

      :ok
    end

    @impl true
    def get_tool_call(tool_call_id) do
      case repo().get(ToolCall, tool_call_id) do
        nil -> nil
        row -> to_tool_call(row)
      end
    end

    @impl true
    def pending_tool_calls(conversation_id) do
      from(t in ToolCall, where: t.conversation_id == ^conversation_id and t.status == :pending)
      |> repo().all()
      |> Enum.map(&to_tool_call/1)
    end

    @impl true
    def resolve_tool_call(tool_call_id, status, result) do
      query = from(t in ToolCall, where: t.id == ^tool_call_id and t.status == :pending)

      case repo().update_all(query,
             set: [status: status, result: result, resolved_at: DateTime.utc_now()]
           ) do
        {0, _} -> {:error, :stale}
        {_count, _} -> :ok
      end
    end

    @impl true
    def latest_summary(conversation_id) do
      from(s in Summary,
        where: s.conversation_id == ^conversation_id,
        order_by: [desc: s.to_seq],
        limit: 1
      )
      |> repo().one()
      |> to_summary()
    end

    @impl true
    def put_summary(conversation_id, summary) do
      ensure_conversation(conversation_id)

      attrs =
        summary
        |> Map.new()
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put_new(:inserted_at, DateTime.utc_now())

      %Summary{}
      |> Ecto.Changeset.cast(attrs, [
        :conversation_id,
        :from_seq,
        :to_seq,
        :content,
        :version,
        :inserted_at
      ])
      |> repo().insert!()

      :ok
    end

    @impl true
    def schedule_expiry(conversation_id, tool_call_id, timeout_ms) do
      ensure_oban!()

      # `replace: [scheduled: [:scheduled_at]]` makes a reschedule of the same call move
      # the existing job's fire time rather than leaking a second timer.
      %{conversation_id: conversation_id, tool_call_id: tool_call_id}
      |> ExpiryWorker.new(
        scheduled_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
        replace: [scheduled: [:scheduled_at]]
      )
      |> Oban.insert!()

      :ok
    end

    @impl true
    def cancel_expiry(conversation_id, tool_call_id) do
      ensure_oban!()

      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker == "Agentix.Persistence.Ecto.ExpiryWorker" and
              fragment("?->>'tool_call_id' = ?", j.args, ^tool_call_id) and
              fragment("?->>'conversation_id' = ?", j.args, ^conversation_id)
        )
      )

      :ok
    end

    @impl true
    def put_model_call(conversation_id, model_call) do
      if audit_enabled?() do
        ensure_conversation(conversation_id)

        attrs =
          model_call
          |> Map.new()
          |> Map.put(:conversation_id, conversation_id)
          |> Map.put_new(:inserted_at, DateTime.utc_now())

        %ModelCall{}
        |> Ecto.Changeset.cast(attrs, [
          :conversation_id,
          :turn_ref,
          :rendered_context,
          :model,
          :usage,
          :latency_ms,
          :summary_version,
          :evictions,
          :inserted_at
        ])
        |> repo().insert!()
      end

      :ok
    end

    @impl true
    def model_calls(conversation_id) do
      from(m in ModelCall,
        where: m.conversation_id == ^conversation_id,
        order_by: [asc: m.turn_ref]
      )
      |> repo().all()
      |> Enum.map(&to_model_call/1)
    end

    @impl true
    def gc_model_calls(conversation_id, ttl_ms) do
      cutoff = DateTime.add(DateTime.utc_now(), -ttl_ms, :millisecond)

      {count, _} =
        repo().delete_all(
          from(m in ModelCall,
            where: m.conversation_id == ^conversation_id and m.inserted_at < ^cutoff
          )
        )

      {:ok, count}
    end

    ## --- mapping schema rows ↔ the plain shapes the behaviour speaks ---

    defp to_event(%EventSchema{} = row) do
      %Event{
        type: row.type,
        content: row.content,
        seq: row.seq,
        conversation_id: row.conversation_id,
        inserted_at: row.inserted_at
      }
    end

    defp to_tool_call(%ToolCall{} = row) do
      %{
        id: row.id,
        conversation_id: row.conversation_id,
        name: row.name,
        executor: row.executor,
        status: row.status,
        args: row.args,
        result: decode_result(row.result),
        inserted_at: row.inserted_at,
        resolved_at: row.resolved_at
      }
    end

    defp to_summary(nil), do: nil

    defp to_summary(%Summary{} = row) do
      %{
        id: row.id,
        conversation_id: row.conversation_id,
        from_seq: row.from_seq,
        to_seq: row.to_seq,
        content: row.content,
        version: row.version,
        inserted_at: row.inserted_at
      }
    end

    defp to_model_call(%ModelCall{} = row) do
      %{
        id: row.id,
        conversation_id: row.conversation_id,
        turn_ref: row.turn_ref,
        rendered_context: row.rendered_context,
        model: row.model,
        usage: row.usage,
        latency_ms: row.latency_ms,
        summary_version: row.summary_version,
        evictions: row.evictions,
        inserted_at: row.inserted_at
      }
    end

    ## --- jsonb → atom decoders for the two known atom-shaped reads ---

    # A tool result is `%{ok: bool, result: term}` or `%{ok: false, error: msg}`. Only the
    # top-level keys are atoms (the `result` value keeps whatever shape the tool returned).
    @result_keys %{"ok" => :ok, "result" => :result, "error" => :error, "approved" => :approved}

    defp decode_result(nil), do: nil

    defp decode_result(map) when is_map(map),
      do: Map.new(map, fn {k, v} -> {Map.get(@result_keys, k, k), v} end)

    # `fsm_state` is the `%{state, pending, last_seq}` cache. `state` and each pending
    # entry's `executor`/`kind` are atoms; pending is keyed by tool_call_id (strings).
    defp decode_fsm_state(map) when is_map(map) and map_size(map) > 0 do
      %{
        state: atomize(map["state"] || map[:state]),
        pending: decode_pending(map["pending"] || map[:pending] || %{}),
        last_seq: map["last_seq"] || map[:last_seq]
      }
    end

    defp decode_fsm_state(_), do: %{}

    defp decode_pending(pending) when is_map(pending),
      do: Map.new(pending, fn {tcid, entry} -> {tcid, decode_pending_entry(entry)} end)

    defp decode_pending_entry(entry) when is_map(entry),
      do: Map.new(entry, fn {k, v} -> decode_pending_kv(k, v) end)

    # The pending-entry shape (from the agent's `pending_subset/1`) is name/executor/kind/
    # prompt; executor/kind carry atom values. Decode those explicitly and pass any other
    # key through as a string rather than `String.to_existing_atom/1` — a key from a newer
    # version or a tampered row must not crash the read (and thus agent revival).
    defp decode_pending_kv(k, v) when k in ["executor", :executor], do: {:executor, atomize(v)}
    defp decode_pending_kv(k, v) when k in ["kind", :kind], do: {:kind, atomize(v)}
    defp decode_pending_kv(k, v) when k in ["name", :name], do: {:name, v}
    defp decode_pending_kv(k, v) when k in ["prompt", :prompt], do: {:prompt, v}
    defp decode_pending_kv(k, v), do: {k, v}

    defp atomize(value) when is_binary(value), do: String.to_existing_atom(value)
    defp atomize(value), do: value

    ## --- adapter wiring ---

    defp repo do
      case Application.fetch_env!(:agentix, :persistence) do
        {__MODULE__, opts} ->
          Keyword.fetch!(opts, :repo)

        other ->
          raise ArgumentError,
                "Agentix.Persistence.Ecto requires config :agentix, :persistence, " <>
                  "{Agentix.Persistence.Ecto, repo: MyRepo}, got: #{inspect(other)}"
      end
    end

    defp audit_enabled?, do: Application.get_env(:agentix, :audit, false)

    defp ensure_oban! do
      if !Code.ensure_loaded?(Oban) do
        raise "Agentix.Persistence.Ecto suspension expiry needs Oban — add {:oban, \"~> 2.20\"} " <>
                "and start it under your supervision tree."
      end
    end
  end
end
