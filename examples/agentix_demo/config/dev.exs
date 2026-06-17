import Config

config :agentix_demo, AgentixDemo.Repo,
  url:
    System.get_env("DATABASE_URL") || "postgres://postgres:postgres@127.0.0.1:5433/agentix_demo_dev",
  pool_size: 10

config :agentix_demo, AgentixDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  check_origin: false,
  debug_errors: true,
  # Rebuild assets on change while the server runs.
  watchers: [esbuild: {Esbuild, :install_and_run, [:agentix_demo, ~w(--sourcemap=inline --watch)]}]

config :logger, level: :info
