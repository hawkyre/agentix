import Config

config :agentix_demo,
  ecto_repos: [AgentixDemo.Repo],
  generators: [timestamp_type: :utc_datetime]

config :agentix_demo, AgentixDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: AgentixDemoWeb.ErrorHTML], layout: false],
  pubsub_server: Agentix.PubSub,
  live_view: [signing_salt: "agentixdemo-lv-salt"]

# Tier 3 — durable Ecto/Postgres persistence with Oban-backed suspension expiry. The host
# owns the Repo and the Oban instance; Agentix routes persistence through the Ecto adapter.
config :agentix, persistence: {Agentix.Persistence.Ecto, repo: AgentixDemo.Repo}

config :agentix_demo, Oban,
  repo: AgentixDemo.Repo,
  queues: [agentix_expiry: 10]

import_config "#{config_env()}.exs"
