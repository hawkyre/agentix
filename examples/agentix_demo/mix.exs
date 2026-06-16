defmodule AgentixDemo.MixProject do
  use Mix.Project

  # Tier 3 — the full install: Agentix + LiveView + durable Ecto/Postgres persistence with
  # Oban-backed suspension expiry. Depends on `agentix` plus the host-provided optional
  # layers (`phoenix_live_view`, `ecto_sql`/`postgrex`, `oban`), exactly as the install
  # guide describes. The LiveView chat is wired in `lib/agentix_demo_web/chat_live.ex`.
  def project do
    [
      app: :agentix_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AgentixDemo.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:agentix, path: "../.."},
      # The optional layers a Tier-3 host provides.
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.21"},
      {:oban, "~> 2.20"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      # `Phoenix.LiveViewTest` parses rendered markup through LazyHTML.
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  defp aliases do
    # The Agentix migration (`priv/repo/migrations/*_create_agentix_tables.exs`) is checked
    # in — it was produced once with `mix agentix.gen.migration`. `setup` just creates and
    # migrates the DB; `test` ensures the schema is present before the suite runs.
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
