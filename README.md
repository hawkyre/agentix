# Agentix

A LiveView-native library for building agentic systems in Elixir, built on
[ReqLLM](https://hexdocs.pm/req_llm).

> **Status:** v0, pre-release. The runtime is implemented — the agent loop,
> tools/HITL, the hook pipeline, reducer-based compaction, the headless LiveView
> layer, and ETS + Ecto/Postgres persistence — with two runnable example apps under
> `examples/`. Not yet published to Hex; depend on it via `path:` for now. APIs may
> still shift before 0.1.0.

Agentix gives you an agent runtime (one `:gen_statem` per conversation),
non-blocking turns (streaming and tool execution as tasks), a per-turn hook
pipeline, an explicit tool/HITL executor model, reducer-based compaction,
pluggable persistence, and a headless LiveView rendering layer.

## Installation

Not yet published to Hex. For now, depend on it via a local path:

```elixir
def deps do
  [
    {:agentix, path: "../agentix"}
  ]
end
```

Once on Hex it'll be `{:agentix, "~> 0.1"}`. See the
**[installation guide](guides/installation.md)** for the three install tiers
(headless/API → +LiveView → +durable Ecto persistence), configuring a model
provider, and the full config reference.

## Development

Requires Elixir 1.20 / OTP 28 (see `.tool-versions`).

```bash
mix deps.get
mix check   # format, unused-deps, credo --strict, deps.audit, dialyzer, test
```

Individual checks:

```bash
mix format            # Styler-backed formatting
mix credo --strict    # linting
mix dialyzer          # static type analysis
mix deps.audit        # dependency vulnerability scan
mix coveralls         # test coverage
mix docs              # generate HexDocs
```
