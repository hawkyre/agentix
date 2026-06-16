if Code.ensure_loaded?(Ecto.Repo) do
  defmodule Agentix.Test.EctoCase do
    @moduledoc false
    # Shared `setup_all` body for the `:postgres`-tagged tests: start the repo, run the
    # Oban + Agentix migrations (idempotent), start Oban with fast staging, and point the
    # persistence adapter at the repo. `DATABASE_URL` defaults to the dev container.

    @default_url "postgres://postgres:postgres@127.0.0.1:5433/agentix_test"

    @doc """
    Call from `setup_all`. Pass `truncate: true` for the conformance suite, which reuses
    sequential conversation ids across VM restarts and needs a clean slate.
    """
    def start!(opts \\ []) do
      repo = Agentix.Test.Repo

      Application.put_env(:agentix, repo,
        url: System.get_env("DATABASE_URL", @default_url),
        pool_size: 10
      )

      ExUnit.Callbacks.start_supervised!(repo)

      Code.require_file("priv/templates/migration/create_agentix_tables.exs")
      Ecto.Migrator.up(repo, 1, Agentix.Test.ObanMigration, log: false)
      Ecto.Migrator.up(repo, 2, Agentix.Repo.Migrations.CreateAgentixTables, log: false)

      if Keyword.get(opts, :truncate, false) do
        repo.query!(
          "TRUNCATE agentix_conversations, agentix_events, agentix_summaries, " <>
            "agentix_tool_calls, agentix_model_calls, oban_jobs RESTART IDENTITY CASCADE"
        )
      end

      ExUnit.Callbacks.start_supervised!(
        {Oban, repo: repo, queues: [agentix_expiry: 5], stage_interval: 50}
      )

      Application.put_env(:agentix, :persistence, {Agentix.Persistence.Ecto, repo: repo})
      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:agentix, :persistence) end)
      :ok
    end
  end
end
