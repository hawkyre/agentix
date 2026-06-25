import Config

# No Ecto sandbox: a conversation is a long-lived `:gen_statem` plus async tool tasks and
# Oban-scheduled expiry, whose lifetimes don't nest inside one test transaction. Like
# Agentix's own Postgres tests, the demo runs against the real pool with unique ids and a
# clean slate (truncated in test_helper.exs).
config :agentix_demo, AgentixDemo.Repo,
  url:
    System.get_env("DATABASE_URL") ||
      "postgres://postgres:postgres@127.0.0.1:5433/agentix_demo_test",
  pool_size: 10

config :agentix_demo, AgentixDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

# Oban must not poll/stage during tests — expiry jobs are inserted but never run.
config :agentix_demo, Oban, testing: :manual

# Stub the `run_tests` tool so the demo's own suite never spawns a nested `mix test`.
config :agentix_demo, :stub_tools, true

# The library composer is a send-and-clear form; LiveView form recovery doesn't apply, so
# the missing-form-id test warning is noise here.
config :phoenix_live_view, :test_warnings, missing_form_id: :ignore

config :logger, level: :warning
