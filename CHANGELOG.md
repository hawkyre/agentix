# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/hawkyre/agentix/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hawkyre/agentix/releases/tag/v0.1.0
