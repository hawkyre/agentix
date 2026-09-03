defmodule Agentix.Repo.Migrations.UpgradeAgentixModelCalls do
  @moduledoc """
  Upgrades an existing Agentix installation for `model_call_log`.

  Only needed by hosts that already ran `create_agentix_tables.exs` before
  Agentix 0.5.0 — a fresh install gets these columns from the create migration
  and must not run this one.

  Copy this file into your repo's `priv/repo/migrations/` with a timestamp prefix
  and run `mix ecto.migrate`.

  What changes:

    * `agentix_model_calls.rendered_context` becomes nullable, so a call can be
      recorded without storing the prompt (`model_call_log: :records`).
    * `status` and `error` record how the call ended. Existing rows were only
      ever written on success, so they backfill to `'ok'`.
    * `tenant_key` and `feature` are mirrored from the conversation, so spend
      reads need no join and survive the conversation being deleted. Existing
      rows are backfilled from their conversation where one still exists;
      `feature` stays null, because nothing recorded it before now.
    * `pricing_version` records which `llm_db` price list costed the call.
  """
  use Ecto.Migration

  def up do
    alter table(:agentix_conversations) do
      add(:feature, :text)
    end

    alter table(:agentix_model_calls) do
      modify(:rendered_context, :map, null: true)
      add(:status, :text, null: false, default: "ok")
      add(:error, :text)
      add(:tenant_key, :text)
      add(:feature, :text)
      add(:pricing_version, :text)
    end

    # Existing rows predate the mirrored column but their conversation may still
    # hold the key. A conversation already deleted takes its rows with it, so
    # there is nothing to backfill there.
    execute("""
    UPDATE agentix_model_calls AS m
       SET tenant_key = c.tenant_key
      FROM agentix_conversations AS c
     WHERE c.id = m.conversation_id
       AND m.tenant_key IS NULL
    """)

    create(index(:agentix_model_calls, [:tenant_key, :feature, :inserted_at]))

    create(
      constraint(:agentix_model_calls, :agentix_model_calls_status,
        check: "status IN ('ok','error','cancelled')"
      )
    )
  end

  def down do
    drop(constraint(:agentix_model_calls, :agentix_model_calls_status))
    drop(index(:agentix_model_calls, [:tenant_key, :feature, :inserted_at]))

    alter table(:agentix_model_calls) do
      remove(:pricing_version)
      remove(:feature)
      remove(:tenant_key)
      remove(:error)
      remove(:status)
      modify(:rendered_context, :map, null: false)
    end

    alter table(:agentix_conversations) do
      remove(:feature)
    end
  end
end
