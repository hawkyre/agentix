if Code.ensure_loaded?(Ecto.Repo) do
  defmodule Agentix.Test.Repo do
    @moduledoc false
    use Ecto.Repo, otp_app: :agentix, adapter: Ecto.Adapters.Postgres
  end

  defmodule Agentix.Test.ObanMigration do
    @moduledoc false
    use Ecto.Migration

    def up, do: Oban.Migration.up()
    def down, do: Oban.Migration.down(version: 1)
  end
end
