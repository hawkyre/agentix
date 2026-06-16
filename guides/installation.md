# Installation

Agentix installs in three tiers. A host adds **only the dependencies its use case needs** —
the LiveView and durable-persistence layers are `optional: true` *and* compile-gated, so an
unused layer is neither fetched nor compiled. Two runnable example apps in this repo prove
each end of the range:

- [`examples/agentix_api`](https://github.com/hawkyre/agentix/tree/main/examples/agentix_api)
  — Tier 1, headless, no LiveView and no database.
- [`examples/agentix_demo`](https://github.com/hawkyre/agentix/tree/main/examples/agentix_demo)
  — Tier 3, LiveView + Postgres + Oban.

## Tier 1 — Headless / API-only (no LiveView, no database)

The core runtime needs no web framework and no database. `Agentix.Application` boots its own
registry, task supervisor, ETS persistence, and `Phoenix.PubSub` (the live-event backbone).

```elixir
# mix.exs
{:agentix, "~> 0.1"}      # pulls req_llm + phoenix_pubsub (both light)
```

```elixir
# config/config.exs
config :agentix,
  persistence: Agentix.Persistence.ETS,   # default, ephemeral
  notifier: Agentix.Notifier.PubSub,      # or Agentix.Notifier.None to silence the live plane
  pubsub: MyApp.PubSub                     # your PubSub, or let Agentix start its own
```

Drive conversations through `Agentix.Conversation.*` and `Agentix.resolve/4`, and stream
output to clients off the **live-event union** over any transport you write (SSE, channel,
JSON polling) by subscribing to `Agentix.Events.Publisher.topic(conversation_id)`.

In this tier `Agentix.Chat`, the Ecto adapter, and the Oban worker are **never compiled** —
`Code.ensure_loaded?(Agentix.Chat) == false`. See `examples/agentix_api` for a working
headless conversation (streaming + a `:server` tool) on ETS.

## Tier 2 — + LiveView

Add `phoenix_live_view` (most Phoenix apps already have it) to light up the rendering layer:

```elixir
{:phoenix_live_view, "~> 1.2"}
```

`use Agentix.Chat` in a host LiveView installs an `on_mount` hook that projects the
conversation onto assigns (`:messages`, `:streaming_message`, `:state`, `:streaming?`,
`:in_flight_tools`, `:pending`) and imports the verbs (`send_message/3`, `resolve/4`,
`cancel/1`, `load_older/1`). Render the assigns yourself, or:

```bash
mix agentix.gen.components lib/my_app_web/components
```

copies an ownable set of default components (`message_list`, `composer`, `tool`, `pending`,
…) into your project. The streaming text and composer hooks ship at
`priv/static/agentix_stream_hook.js`.

## Tier 3 — + Durable persistence

Add the host-provided Ecto/Oban stack to make conversations and suspension expiry survive a
restart:

```elixir
{:ecto_sql, "~> 3.14"}, {:postgrex, "~> 0.21"}, {:oban, "~> 2.20"}
```

```elixir
# config/config.exs
config :agentix, persistence: {Agentix.Persistence.Ecto, repo: MyApp.Repo}

config :my_app, Oban, repo: MyApp.Repo, queues: [agentix_expiry: 10]
```

You own the `Repo` and the `Oban` instance. Generate and run the migration:

```bash
mix agentix.gen.migration         # writes priv/repo/migrations/*_create_agentix_tables.exs
mix ecto.migrate
```

Oban needs its own migration too (`Oban.Migration.up/0` in a separate migration) — durable
expiry is scheduled as Oban jobs. The audit log of model calls is off by default; enable it
with `config :agentix, audit: true`. See `examples/agentix_demo` for the full wiring,
including a Postgres-backed `Phoenix.LiveViewTest` that drives a HITL elicitation end-to-end.

## Config keys (all tiers)

| key                | meaning                                                        |
| ------------------ | ------------------------------------------------------------- |
| `:persistence`     | adapter module or `{module, opts}` (default `…ETS`)           |
| `:notifier`        | live-event notifier (`…Notifier.PubSub` / `…Notifier.None`)   |
| `:pubsub`          | the `Phoenix.PubSub` server name                              |
| `:audit`           | record per-turn model-call audit rows (default `false`)       |
| `:audit_ttl`       | TTL for GC of audit rows                                       |
| `:working_budget`  | token budget for context assembly                             |
| `:default_timeout` | suspension-expiry timeout                                     |
