# Agentix

A LiveView-native library for building agentic systems in Elixir, built on
[ReqLLM](https://hexdocs.pm/req_llm).

> **Status:** pre-implementation. This repo currently holds the design (see
> `.docs/`) and the project scaffold. The public API is not yet committed.

Agentix gives you an agent runtime (one `:gen_statem` per conversation),
non-blocking turns (streaming and tool execution as tasks), a per-turn hook
pipeline, an explicit tool/HITL executor model, reducer-based compaction,
pluggable persistence, and a headless LiveView rendering layer.

## Installation

Once published to Hex:

```elixir
def deps do
  [
    {:agentix, "~> 0.1.0"}
  ]
end
```

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
