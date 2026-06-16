defmodule AgentixDemo.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Oban's own tables — required because the Tier-3 Ecto adapter schedules durable
  # suspension expiry as Oban jobs. Runs before the Agentix migration (earlier timestamp).
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
