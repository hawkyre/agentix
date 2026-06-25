# agentix_demo — "Agentix, meet Agentix"

A Tier-3 Agentix example: a LiveView chat backed by Postgres persistence and Oban-backed
suspension expiry, where **Claude answers questions about the Agentix library by reading its
own source**. The assistant really `search_code`s the repo, `read_file`s the relevant modules,
and — with your approval — `run_tests` on a specific file. Talks to Claude Haiku via ReqLLM
when `ANTHROPIC_API_KEY` is set; falls back to a canned offline provider with no key.

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

At **`/`** (the chat) — ask about Agentix; the model reads the real source to answer:

- **"How does durable suspension work?"** / **"Where's the compaction pipeline?"** — the
  assistant `search_code`s, `read_file`s the relevant modules, and answers citing real paths,
  with its reasoning streamed live above the text. (Inline `:server` tools.)
- **"Run the hook tests"** — it proposes `run_tests test/agentix/hook_test.exs`, an
  **approval-gated** `:server` tool: approve or deny inline. On approve it runs and the output
  shows in the expandable inspector.
- **Reload** — the conversation lives at `/c/:id`; refreshing restores its history from
  Postgres.
- **Theme** — the top-bar toggle flips light/dark (persisted in `localStorage`).

The tools (`AgentixDemo.RepoTools`) are scoped to the repo: paths can't escape it, the search
query/path are passed as argv (no shell injection), and output is capped.

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
