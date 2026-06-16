import Config

# Tier 1 — headless / API-only. ETS persistence (the default, ephemeral); the live-event
# plane rides Agentix's own `Phoenix.PubSub` (started by `Agentix.Application`). No LiveView,
# no Ecto/Oban. A real provider is configured per environment; the test suite swaps in the
# shipped `Agentix.Test.MockProvider` so it runs with no API key and no network.
config :agentix, persistence: Agentix.Persistence.ETS
