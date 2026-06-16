import Config

config :agentix_demo, AgentixDemo.Repo,
  url:
    System.get_env("DATABASE_URL") || "postgres://postgres:postgres@127.0.0.1:5433/agentix_demo_dev",
  pool_size: 10

config :agentix_demo, AgentixDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  # Dev/test-only fallback — a real app sets SECRET_KEY_BASE (e.g. via `mix phx.gen.secret`).
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64),
  server: true,
  check_origin: false,
  debug_errors: true

config :logger, level: :info
