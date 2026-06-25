# agentix_demo

A Tier-3 Agentix example: a LiveView chat backed by Postgres persistence and Oban-backed
suspension expiry. It runs **with no API key** on a built-in offline provider, and talks to
Anthropic Claude Haiku via ReqLLM when `ANTHROPIC_API_KEY` is set.

## Run

1. **Postgres** — the configs default to `127.0.0.1:5433` (override with `DATABASE_URL`).

2. **Create the DB and start the server:**

   ```bash
   mix setup             # deps.get + assets.build + ecto.create + ecto.migrate
   mix phx.server        # → http://localhost:4000
   ```

   With no key set, replies come from `AgentixDemo.OfflineProvider` (canned, streamed
   word-by-word) so everything works offline.

3. **Real model (optional)** — ReqLLM auto-loads `.env` from this directory at startup, so
   there's no `export` step:

   ```bash
   cp .env.example .env
   $EDITOR .env          # set ANTHROPIC_API_KEY
   ```

   `AgentixDemo.ModelConfig.provider/1` switches to the real provider when the key is present.

## What to try

At **`/`** (the chat):

- **Stream a reply** — send any message; the assistant streams its answer, with its reasoning
  shown live above the text.
- **Approval-gated server tool** — ask `weather in Tokyo`. The assistant calls `get_weather`
  (a `:server` tool marked `:requires_approval`); approve or deny it inline. On approve the
  tool runs and its result shows in the expandable inspector.
- **Inline server tool** — ask `6 * 7`. The `calculator` (`:server`, no gate) runs inline.
- **Human-in-the-loop** — a greeting like `hi` triggers `ask_user` (`:human`); answer the
  elicitation form to resume the turn.
- **Reload** — the conversation lives at `/c/:id`; refreshing restores its history from
  Postgres.
- **Theme** — the top-bar toggle flips light/dark (persisted in `localStorage`).

At **`/gallery`** (the storybook): every component in every state — messages, the reasoning
panel, tool rows (running/ok/error + result inspector), approval & elicitation controls,
error/warning banners, and the composer.

## Assets

`app.js` is bundled by **esbuild** (a standalone binary — no Node) from `assets/js/app.js`,
which imports Phoenix, LiveView, the Agentix JS hooks, and the **vendored** `marked` +
`DOMPurify` (committed under `assets/vendor/`, so the build is deterministic and offline).
`mix assets.build` rebuilds the bundle; `mix phx.server` watches and rebuilds on change.

## Components

The UI components are generated, ownable copies from
`mix agentix.gen.components lib/agentix_demo_web --module AgentixDemoWeb.AgentixComponents`.
Re-run it (with `--force`) to pull in upstream changes; the demo keeps the generated file
unedited so a regen never clobbers local tweaks.

## Tests

`mix test` uses the bundled mock provider (no API key or network) and runs against the real
Postgres pool with a clean slate — see `test/test_helper.exs`.
