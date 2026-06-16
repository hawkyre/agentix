defmodule AgentixDemo.Repo.Migrations.CreateAgentixTables do
  @moduledoc """
  Creates the five Agentix tables for the Ecto/Postgres persistence adapter.

  Copy this file into your repo's `priv/repo/migrations/` with a timestamp prefix
  (e.g. `20260101000000_create_agentix_tables.exs`) and run `mix ecto.migrate`. The
  Ecto-backed suspension expiry additionally needs Oban's own migration.

  Conversation ids are host-chosen strings (the Registry key), so conversation id
  columns are `:text`, not `uuid`. Internal row ids are `uuid`; `tool_calls.id` is the
  provider-supplied tool_call_id (`:text`).
  """
  use Ecto.Migration

  def change do
    create table(:agentix_conversations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:settings, :map, null: false, default: %{})
      add(:fsm_state, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "active")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:agentix_conversations, :agentix_conversations_status,
        check: "status IN ('active','suspended','idle','ended')"
      )
    )

    create table(:agentix_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:conversation_id, references(:agentix_conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:seq, :bigint, null: false)
      add(:type, :text, null: false)
      add(:content, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:agentix_events, [:conversation_id, :seq]))

    create(
      constraint(:agentix_events, :agentix_events_type,
        check:
          "type IN ('user_msg','assistant_msg','tool_call','tool_result','suspension','resolution')"
      )
    )

    create table(:agentix_summaries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:conversation_id, references(:agentix_conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:from_seq, :bigint, null: false)
      add(:to_seq, :bigint, null: false)
      add(:content, :map, null: false)
      add(:version, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:agentix_summaries, [:conversation_id, "to_seq DESC"]))

    create(
      constraint(:agentix_summaries, :agentix_summaries_seq_range, check: "to_seq >= from_seq")
    )

    create table(:agentix_tool_calls, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:conversation_id, references(:agentix_conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:name, :text)
      add(:executor, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:args, :map)
      add(:result, :map)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
    end

    create(index(:agentix_tool_calls, [:conversation_id, :status]))

    create(
      constraint(:agentix_tool_calls, :agentix_tool_calls_executor,
        check: "executor IN ('server','human','client','provider')"
      )
    )

    create(
      constraint(:agentix_tool_calls, :agentix_tool_calls_status,
        check: "status IN ('pending','resolved','errored','expired')"
      )
    )

    create table(:agentix_model_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:conversation_id, references(:agentix_conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:turn_ref, :bigint, null: false)
      add(:rendered_context, :map, null: false)
      add(:model, :text)
      add(:usage, :map)
      add(:latency_ms, :integer)
      add(:summary_version, :text)
      add(:evictions, {:array, :map})
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:agentix_model_calls, [:conversation_id, :turn_ref]))
    create(index(:agentix_model_calls, [:inserted_at]))
  end
end
