# Integration tests hit a real provider (network + API key) and are excluded from
# the default/CI run — opt in with `mix test --include integration` (D10).
ExUnit.start(exclude: [:integration])
