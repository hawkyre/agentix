defmodule Agentix.Persistence.EctoTest do
  @moduledoc """
  Runs the shared `Agentix.PersistenceConformance` suite against the Ecto/Postgres
  adapter. Tagged `:postgres` (excluded by default); opt in with
  `mix test --include postgres` and a Postgres reachable at `DATABASE_URL` (defaults to
  the dev container on `127.0.0.1:5433`). No Ecto sandbox — the suite uses unique
  conversation ids for isolation, and the Oban expiry worker runs in its own process, so
  it must see committed rows.
  """
  use Agentix.PersistenceConformance, adapter: Agentix.Persistence.Ecto, moduletag: :postgres

  @default_url "postgres://postgres:postgres@127.0.0.1:5433/agentix_test"

  setup_all do
    repo = Agentix.Test.Repo

    Application.put_env(:agentix, repo,
      url: System.get_env("DATABASE_URL", @default_url),
      pool_size: 10
    )

    start_supervised!(repo)

    # Idempotent across runs — the migrator's version table skips already-applied steps.
    Code.require_file("priv/templates/migration/create_agentix_tables.exs")
    Ecto.Migrator.up(repo, 1, Agentix.Test.ObanMigration, log: false)
    Ecto.Migrator.up(repo, 2, Agentix.Repo.Migrations.CreateAgentixTables, log: false)

    # The suite's `uid` helper resets per VM, so a fresh run reuses conversation ids from
    # a prior run. Start clean (the container DB is disposable) so `seq` starts at 1 and
    # leftover scheduled Oban jobs can't fire mid-run.
    repo.query!(
      "TRUNCATE agentix_conversations, agentix_events, agentix_summaries, " <>
        "agentix_tool_calls, agentix_model_calls, oban_jobs RESTART IDENTITY CASCADE"
    )

    # Fast staging so the conformance suite's millisecond expiry timeouts fire promptly
    # (the stager is built-in in Oban 2.x; `stage_interval` tunes its cadence).
    start_supervised!({Oban, repo: repo, queues: [agentix_expiry: 5], stage_interval: 50})

    Application.put_env(:agentix, :persistence, {Agentix.Persistence.Ecto, repo: repo})
    on_exit(fn -> Application.delete_env(:agentix, :persistence) end)
    :ok
  end
end
