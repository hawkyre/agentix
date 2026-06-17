# agentix_demo

A Tier-3 Agentix example: a LiveView chat backed by Postgres persistence and Oban-backed
suspension expiry, talking to Anthropic Claude Haiku via ReqLLM.

## Run

1. **Postgres** — the configs default to `127.0.0.1:5433` (override with `DATABASE_URL`).

2. **Anthropic key** — copy the template and fill it in. ReqLLM auto-loads `.env` from this
   directory at startup, so there's no `export` step:

   ```bash
   cp .env.example .env
   $EDITOR .env          # set ANTHROPIC_API_KEY
   ```

3. **Create the DB and start the server:**

   ```bash
   mix setup             # deps.get + ecto.create + ecto.migrate
   mix phx.server        # → http://localhost:4000
   ```

Send a message; ask something that makes the assistant need a clarification to see the
human-in-the-loop (elicitation) flow. `mix test` uses the bundled mock provider, so the test
suite needs no API key or network.
