defmodule AgentixApi.MixProject do
  use Mix.Project

  # Tier 1 — headless / API-only consumer of Agentix. Depends on `agentix` and nothing
  # else web/DB-related: no `phoenix_live_view`, no `ecto_sql`/`postgrex`/`oban`. Proves
  # those layers are genuinely optional — `Agentix.Chat` and `Agentix.Persistence.Ecto`
  # are never compiled here (see test/agentix_api_test.exs).
  def project do
    [
      app: :agentix_api,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:agentix, path: "../.."},
      {:jason, "~> 1.4"}
    ]
  end
end
