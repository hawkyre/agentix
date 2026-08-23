defmodule AgentixDemo.Repo.Migrations.AddTenantKeyToAgentixConversations do
  @moduledoc """
  The upgrade path for an install that ran the Agentix table migration before
  `tenant_key` existed (0.3.x and earlier) — this demo is one. New installs get
  the column from the current `mix agentix.gen.migration` template instead, so
  they never need this file.
  """
  use Ecto.Migration

  def change do
    alter table(:agentix_conversations) do
      add(:tenant_key, :text)
    end

    create(index(:agentix_conversations, [:tenant_key]))
  end
end
