defmodule Agentix.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hawkyre/agentix"

  def project do
    [
      app: :agentix,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),

      # Tooling
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "Agentix",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Agentix.Application, []}
    ]
  end

  # Modern Mix moves preferred envs out of project/0 and into cli/0.
  def cli do
    [
      preferred_envs: [
        check: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core — ReqLLM provides provider abstraction and the canonical typed model.
      {:req_llm, "~> 1.16"},
      # Core — the live-event backbone for every streaming transport. Pulls no
      # Phoenix/web deps; a zero-pubsub consumer sets `notifier: Agentix.Notifier.None`.
      {:phoenix_pubsub, "~> 2.2"},

      # Optional — the LiveView layer (`Agentix.Chat`) compiles only when present.
      # Headless/API consumers omit it entirely; its modules are conditionally defined.
      {:phoenix_live_view, "~> 1.2", optional: true},

      # Optional — the Ecto/Postgres persistence adapter (`Agentix.Persistence.Ecto`)
      # and its Oban-backed expiry. ETS (the default) and core need none of these; a
      # host opts in by depending on them and configuring the Ecto adapter.
      {:ecto_sql, "~> 3.14", optional: true},
      {:postgrex, "~> 0.21", optional: true},
      {:oban, "~> 2.20", optional: true},

      # Dev/test tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      # `Phoenix.LiveViewTest` parses rendered markup through LazyHTML.
      {:lazy_html, "~> 0.1", only: :test},
      # Dev-only HTTP server for the throwaway demo harness under `dev/`.
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  # One-shot quality gate: `mix check`.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --strict",
        "deps.audit",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix, :phoenix_pubsub, :phoenix_live_view],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return, :unknown]
    ]
  end

  defp description do
    "A LiveView-native library for building agentic systems in Elixir, built on ReqLLM."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/static priv/templates mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Agentix",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
