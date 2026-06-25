# Installation

Agentix requires **Elixir 1.20+**. It installs in three tiers: a host adds **only the
dependencies its use case needs** — the LiveView and durable-persistence layers are
`optional: true` *and* compile-gated, so an unused layer is neither fetched nor compiled. Two
runnable example apps in this repo prove each end of the range:

- [`examples/agentix_api`](https://github.com/hawkyre/agentix/tree/main/examples/agentix_api)
  — Tier 1, headless, no LiveView and no database.
- [`examples/agentix_demo`](https://github.com/hawkyre/agentix/tree/main/examples/agentix_demo)
  — Tier 3, LiveView + Postgres + Oban.

## Tier 1 — Headless / API-only (no LiveView, no database)

The core runtime needs no web framework and no database. The Agentix OTP application boots its
own registry, task supervisor, ETS persistence, and `Phoenix.PubSub` (the live-event backbone).

```elixir
# mix.exs
{:agentix, "~> 0.1"}      # pulls req_llm + phoenix_pubsub (both light)
```

No configuration is required to start — ETS persistence and an `Agentix.PubSub` server start
automatically. Override only what differs from the defaults (see the config table below),
e.g. to reuse a `Phoenix.PubSub` your app already supervises:

```elixir
# config/config.exs
config :agentix, pubsub: MyApp.PubSub
```

### Configure a model provider

Agentix talks to LLMs through [ReqLLM](https://hexdocs.pm/req_llm). Choose a model with a
`"<provider>:<model>"` string (per conversation, via `Agentix.Conversation.Config`), and give
ReqLLM the provider credential — an `ANTHROPIC_API_KEY`-style env var (`.env` is loaded via
dotenvy), inline config, or `ReqLLM.put_key/2`:

```elixir
# config/runtime.exs  — or just export ANTHROPIC_API_KEY
config :req_llm, anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")

# starting a conversation with that provider:
Agentix.Conversation.ensure_started("conv-1",
  config: Agentix.Conversation.Config.new(model: "anthropic:claude-haiku-4-5"))
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
{:ecto_sql, "~> 3.14"}, {:postgrex, "~> 0.22"}, {:oban, "~> 2.20"}
```

```elixir
# config/config.exs
config :agentix, persistence: {Agentix.Persistence.Ecto, repo: MyApp.Repo}

config :my_app, Oban, repo: MyApp.Repo, queues: [agentix_expiry: 10]
```

You own the `Repo` and the `Oban` instance. Oban needs its own migration, and it must run
**before** the Agentix migration (the expiry worker references Oban's jobs table) — give it
an earlier timestamp:

```elixir
# priv/repo/migrations/<EARLIER_TIMESTAMP>_add_oban_jobs.exs
defmodule MyApp.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
```

Then generate the Agentix tables migration and run both:

```bash
mix agentix.gen.migration         # writes priv/repo/migrations/*_create_agentix_tables.exs
mix ecto.migrate
```

Durable expiry is scheduled as Oban jobs. The audit log of model calls is off by default;
enable it with `config :agentix, audit: true`. See `examples/agentix_demo` for the full
wiring, including a Postgres-backed `Phoenix.LiveViewTest` that drives a HITL elicitation
end-to-end.

## Config keys

Application config — `config :agentix, …` (all tiers):

| key            | meaning                                                                 |
| -------------- | ----------------------------------------------------------------------- |
| `:persistence` | adapter module or `{module, opts}` (default `Agentix.Persistence.ETS`)  |
| `:notifier`    | live-event notifier (default `Agentix.Notifier.PubSub`; or `…None`)     |
| `:pubsub`      | the `Phoenix.PubSub` server name (default `Agentix.PubSub`)             |
| `:provider`    | LLM provider module (default `Agentix.Provider.ReqLLM`)                 |
| `:tokenizer`   | tokenizer module (default `Agentix.Tokenizer.Heuristic`)               |
| `:audit`       | record per-turn model-call audit rows (default `false`)                |

Per-conversation options are passed to `Agentix.Conversation.Config.new/1` (**not**
application config): `:model`, `:system_prompt`, `:tools`, `:hooks`, `:working_budget`
(default 30k tokens), `:default_timeout` (suspension expiry, default `300_000` ms), and more
— see `Agentix.Conversation.Config`.
