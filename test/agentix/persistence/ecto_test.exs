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

  alias Agentix.Test.EctoCase

  # `truncate: true` — the suite's `uid` helper resets per VM, so a fresh run would reuse
  # conversation ids from a prior run; start clean so `seq` begins at 1.
  setup_all do: EctoCase.start!(truncate: true)
end
