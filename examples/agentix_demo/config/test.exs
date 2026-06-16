import Config

config :agentix_demo, AgentixDemo.Repo,
  url:
    System.get_env("DATABASE_URL") ||
      "postgres://postgres:postgres@127.0.0.1:5433/agentix_demo_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :agentix_demo, AgentixDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # Dev/test-only fallback — a real app sets SECRET_KEY_BASE (e.g. via `mix phx.gen.secret`).
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64),
  server: false

# Oban must not poll/stage during tests — jobs are inserted into the sandbox and never run.
config :agentix_demo, Oban, testing: :manual

# The library composer is a send-and-clear form; LiveView form recovery doesn't apply, so
# the missing-form-id test warning is noise here.
config :phoenix_live_view, :test_warnings, missing_form_id: :ignore

config :logger, level: :warning
