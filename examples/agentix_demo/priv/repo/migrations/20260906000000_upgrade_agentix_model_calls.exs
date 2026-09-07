defmodule AgentixDemo.Repo.Migrations.UpgradeAgentixModelCalls do
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
