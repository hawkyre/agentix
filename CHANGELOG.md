# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/hawkyre/agentix/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hawkyre/agentix/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hawkyre/agentix/releases/tag/v0.1.0
