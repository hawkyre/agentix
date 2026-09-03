# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-09-03

### Fixed

- `feature` now lands on the `agentix_conversations` **column**, not only inside
  the settings blob. `init/1` wrote `tenant_key` and not `feature`, so the column
  a host queries and joins on stayed null while the config that set it looked
  correct. Model-call rows were unaffected — they take the feature straight from
  the config.

## [0.5.0] - 2026-09-03

### Added

- **`model_call_log`** — durable records of provider calls, replacing the
  `audit?` boolean with three levels on `Agentix.Conversation.Config` (and as
  application config): `:off` (the default, unchanged), `:records` (one row per
  call carrying model, usage, latency, outcome, `tenant_key` and `feature`, with
  **no** prompt), and `:full` (the same row plus `rendered_context`). The middle
  level is the one that did not exist before: a row small enough to keep
  indefinitely, which is what a host needs to answer "what did this tenant
  spend" without also storing every prompt forever.
- **Calls are recorded at every outcome, not only on success.** A failed call
  writes a row with `status: :error` and the provider's reason; a cancelled turn
  writes `status: :cancelled`. The cancelled case is only reachable here:
  cancelling kills the streaming task, so its telemetry span emits no terminal
  event at all and a handler counting spend from telemetry misses it silently.
- **`feature`** — an optional label on `Agentix.Conversation.Config` for the part
  of the host application a conversation serves. Stored on the conversation and
  mirrored onto every model-call row, indexed as `(tenant_key, feature,
  inserted_at)`, so spend by feature is one query with no join. Unlike
  `tenant_key` it is a label, not an isolation boundary — nothing selects or
  deletes by it.
- `tenant_key` is now mirrored onto model-call rows too, so the rows stay
  attributable after their conversation is deleted.
- `pricing_version` on each row — the `llm_db` catalog version that costed the
  call, so a later price correction is traceable rather than a silent rewrite.
- `latency_ms` is now actually populated. The column existed since the audit
  table was introduced and was never written.

### Changed

- `put_model_call/2` persists whatever it is given. Whether a call is recorded,
  and at what detail, is the agent's decision — adapters no longer consult
  application config themselves.
- `gc_model_calls/2` is documented as offered-but-unscheduled, with the reason:
  under `:full` the rows are the fastest-growing table in the schema, while under
  `:records` they are usually the host's accounting record and expiring them
  deletes it. Agentix will not pick for you.

### Breaking

- **`agentix_model_calls` gained columns and `rendered_context` became
  nullable.** Hosts that ran `create_agentix_tables.exs` before 0.5.0 must apply
  `priv/templates/migration/upgrade_agentix_model_calls.exs`; a fresh install
  gets everything from the create migration and must not run it. The upgrade
  backfills `tenant_key` from each row's surviving conversation.
- `Config.audit?` is deprecated but still accepted and still means `:full`, at
  both the conversation and application level, so conversations persisted before
  this release revive with the recording they were configured for. It will be
  removed in a later release.

## [0.4.0] - 2026-08-23

### Added

- **Per-model-call and per-tool-call telemetry.** Every provider attempt emits a
  `[:agentix, :model_call, :start | :stop | :exception]` span (token usage,
  latency, the rendered context, and the assembled response; one span per retry
  attempt), and every tool call emits `[:agentix, :tool, :start | :stop |
  :exception]` (latency measured across `:human`/`:client` suspensions). Events
  fire regardless of `audit?`, so hosts can feed PostHog LLM analytics, Langfuse,
  or OpenTelemetry without enabling audit rows. Documented in the new
  `guides/telemetry.md`, including a worked PostHog handler. The caller's
  `Agentix.Scope` is deliberately never broadcast — metadata carries only a
  derived `system_call?` boolean.
- **`tenant_key`** — optional owning tenant for multi-tenant hosts, on
  `Agentix.Conversation.Config` and as a `tenant_key:` option on
  `ensure_started/2` / `send_message/4`. Stored as an indexed column on
  `agentix_conversations` (and in settings, so revival keeps it) and stamped on
  all `:model_call`/`:tool` telemetry metadata. **Write-once**: a conflicting
  re-key returns `{:error, :tenant_key_conflict}` — including when racing
  concurrent starts. `Agentix.Scope` gains an optional `tenant_key` field: when
  the scope carries one and the call does not pass `tenant_key:` explicitly, the
  entry verbs (`send_message/4`, `Agentix.resolve/4`) use the scope's key for the
  write-once check — so authenticating the tenant into the scope is enough to get
  tenant isolation on every call. The scope field itself is never persisted and
  never broadcast on telemetry.
- `Agentix.Persistence.delete_by_tenant/1` — deletes every conversation whose
  `tenant_key` matches, cascading to events, summaries, tool calls, and audit
  rows; returns `{:ok, count}`.

### Breaking

- New required `Agentix.Persistence` behaviour callback `delete_by_tenant/1`
  (implemented by both bundled adapters). Third-party adapters must implement it.
- Ecto-backed installs that already ran the migration must add the new
  `tenant_key` column and index (the template only serves new installs; derived
  from its `add`/`index` lines):

  ```elixir
  alter table(:agentix_conversations) do
    add(:tenant_key, :text)
  end

  create(index(:agentix_conversations, [:tenant_key]))
  ```

- Removed the reserved `persistence` field from `Agentix.Conversation.Config`
  (documented as unused in 0.3.0; it was never consulted). `Agentix.Conversation.Config.new/1` now
  raises on a `:persistence` key — persistence is configured at the application
  level only (`config :agentix, :persistence`), and ephemeral one-shots clean
  up via `Agentix.Persistence.delete_conversation/1`.

## [0.3.0] - 2026-07-07

### Added

- Per-conversation `api_key` on `Agentix.Conversation.Config` — a string or a
  **0-arity resolver fun** (re-evaluated on every model call) passed to the
  provider as a per-request option. `nil` keeps ReqLLM's own key resolution.
  The Ecto persistence adapter's settings sanitizer drops it, so key material
  never lands in a durable row; a conversation revived from persisted settings
  alone is key-less and the host must re-pass a fresh `config:`.
- `Agentix.Conversation.stop/1` — public verb to release an idle conversation's
  agent process without ending the conversation (persisted events remain; the
  next `ensure_started/2` revives it). Replaces hosts reaching into
  `Agentix.Registry` / `Agentix.ConversationSupervisor` internals.
- `{:turn_failed, turn_ref, reason}` live event — provider/stream failures now
  get their own terminal event carrying the reason. Previously they broadcast
  the same `{:cancelled, turn_ref}` as a user-initiated cancel, so consumers
  could not distinguish "your key/provider failed" (e.g. an auth rejection)
  from "you cancelled".

### Changed

- A per-conversation `api_key` resolver fun is now evaluated inside the
  monitored streaming task: a raising resolver fails the turn
  (`{:turn_failed, …}`) instead of crashing the conversation's agent process.
- The ETS persistence owner now starts unconditionally (previously only when
  ETS was the app-configured adapter), so ETS is usable in tests and tools
  regardless of the app default.

- `Config.persistence` is documented as **Reserved**: the agent persists
  through the application-level adapter only; the field was never consulted
  and the old doc implied otherwise.
- Agents now trap exits: `Conversation.stop/1` and supervisor shutdown drain
  the in-flight callback before terminating, so an agent mid-write to durable
  persistence is never killed between statements (previously a stop could
  sever a checked-out DB connection mid-query).

### Breaking

- New required `Agentix.Persistence` behaviour callback
  `delete_conversation/1` (implemented by both bundled adapters): removes a
  conversation and everything under it (events, summaries, tool calls, audit
  rows) — ephemeral one-shot tasks call it after reading usage so throwaway
  conversations never accumulate. Third-party adapters must implement it.
- Turns that fail on a provider/stream error no longer emit
  `{:cancelled, turn_ref}` — subscribe to `{:turn_failed, turn_ref, reason}`
  for that terminal. `{:cancelled, …}` is now exclusively user-initiated.

## [0.2.0] - 2026-06-25

### Added

- **Provider retry & backoff** — a per-conversation `retry` policy on
  `Agentix.Conversation.Config` (`%{max_attempts, base_ms, max_ms}` or `false`).
  Transient pre-stream failures (HTTP 429, 5xx, connection drops) are retried with
  exponential backoff + jitter, honoring a `retry-after` header (capped at 60s); 4xx
  and unrecognized errors fail fast. A failure after the first streamed token is never
  retried. Classification/backoff live in the new public `Agentix.Retry`. Each retry
  emits a `[:agentix, :turn, :retry]` telemetry event.
- **Structured output** — make the model return typed data conforming to a schema.
  Pass `schema:` to `Agentix.Conversation.send_message/4` (one-shot) or set
  `response_format` on the config (default); `schema: false` opts out per turn. The
  parsed object is surfaced via `Agentix.object/1` and the `Agentix.Chat` `:last_object`
  assign, and persisted in the assistant message's `metadata["object"]` (no migration).
  A schema turn is terminal (the tool loop is skipped). `Agentix.Provider.ReqLLM`
  branches to `ReqLLM.stream_object/4`.
- `Agentix.Test.error/2`, `Agentix.Test.transport_error/1`, and a `:object` option on
  `Agentix.Test.completion/2` for driving retry and structured-output scenarios with the
  mock provider.
- New guide: **Reliability & structured output**.

## [0.1.0] - 2026-06-25

First public release.

### Added

- **Agent runtime** — one event-sourced `:gen_statem` per conversation
  (`Agentix.Conversation`), with non-blocking streaming turns, in-process tool
  execution, and mid-turn cancellation. Conversations are started on demand via
  `Agentix.Conversation.ensure_started/2` and survive process death.
- **Provider seam** — `Agentix.Provider` behaviour with a streaming + cancel +
  finalize contract; `Agentix.Provider.ReqLLM` adapts ReqLLM's canonical typed
  model and provider abstraction.
- **Tools & HITL** — an explicit executor model (`:server`, `:human`, `:client`,
  `:provider`) with gated approval, durable suspension into `awaiting_input`, and
  a public, socket-independent `Agentix.resolve/4` (LiveView, webhook, job, or
  timeout). Suspended turns revive from durable state.
- **Hook pipeline** — per-turn pre/post hooks (`Agentix.Hook`), parallel
  append-only injections with a token reserve, halt semantics, and a per-chunk
  stream-transformer seam.
- **Compaction** — reducer pipeline (tool-result stubbing, sliding window, async
  cumulative summarization) gated by a token budget, behind a pluggable
  `Agentix.Tokenizer` behaviour (default char/4 heuristic, no extra dependency).
- **Persistence** — the `Agentix.Persistence` behaviour with two adapters sharing
  one conformance suite: `Agentix.Persistence.ETS` (default, no database) and
  `Agentix.Persistence.Ecto` (Postgres, kill-and-resume, optional Oban-backed
  suspension expiry). Both LiveView and Ecto/Oban are optional dependencies.
- **Headless LiveView layer** — `Agentix.Chat` (`use` macro + `on_mount`
  projection of the live-event plane onto assigns, streamed deltas to a JS hook),
  optional ownable `Agentix.Components`, and `mix agentix.gen.components` /
  `mix agentix.gen.migration` generators.
- **Live-event union** — a typed event plane broadcast over `Phoenix.PubSub`
  (`Agentix.Notifier` behaviour; `PubSub` default, `None` no-op) consumable by any
  transport.
- **Test story** — `Agentix.Test` assertions and a scriptable
  `Agentix.Test.MockProvider` for driving conversations deterministically with no
  API key.
- Modern tooling: Credo, Dialyxir, Styler, ExCoveralls, MixAudit, ExDoc, and a
  `mix check` quality gate.

[Unreleased]: https://github.com/hawkyre/agentix/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/hawkyre/agentix/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/hawkyre/agentix/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/hawkyre/agentix/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hawkyre/agentix/releases/tag/v0.1.0
