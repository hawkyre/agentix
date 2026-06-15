alias Agentix.Test.Endpoint

# Integration tests hit a real provider (network + API key) and are excluded from
# the default/CI run — opt in with `mix test --include integration` (D10).

# A throwaway endpoint backs the `Phoenix.LiveViewTest`-based chat tests.
Application.put_env(:agentix, Endpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "agentix-test-salt"],
  pubsub_server: Agentix.PubSub,
  server: false
)

{:ok, _} = Endpoint.start_link()

ExUnit.start(exclude: [:integration])
