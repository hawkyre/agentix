# Reliability & structured output

Two per-conversation knobs added in 0.2.0, both configured on
`Agentix.Conversation.Config` and both additive (existing code is unaffected).

## Retry & backoff

Transient provider failures — a dropped connection, an HTTP 429 (rate limited), or
a 5xx (server/overload) — are common in production. By default Agentix retries the
**pre-stream** provider call before giving up on the turn.

```elixir
Agentix.Conversation.Config.new(
  model: "anthropic:claude-haiku-4-5",
  retry: %{max_attempts: 3, base_ms: 500, max_ms: 8_000}  # the default
)
```

* `max_attempts` — total attempts, including the first (so `3` = up to 2 retries).
* `base_ms` / `max_ms` — exponential backoff `base_ms * 2^(n-1)`, capped at `max_ms`,
  with equal jitter so retrying clients de-synchronize.

Set `retry: false` (equivalent to `%{max_attempts: 1}`) to disable it.

### What is and isn't retried

`Agentix.Retry.retryable?/1` classifies the error: **429**, **5xx**, and **transport**
errors (connection drop/timeout) are retried; **4xx** (auth, bad request, not found)
and anything unrecognized fail fast. A server-supplied `retry-after` header is honored,
capped at 60s so a hostile or buggy server can't pin the turn asleep.

Retry only covers the call **before any token streams**. Once the first chunk has been
forwarded, a later failure fails the turn rather than risk re-emitting already-shown
output — there is no mid-stream replay.

### Telemetry

Each retry emits, before its backoff sleep:

```
[:agentix, :turn, :retry]
  measurements: %{attempt: pos_integer(), delay_ms: non_neg_integer()}
  metadata:     %{conversation_id: String.t(), turn_ref: reference(), reason: term()}
```

It joins the existing `[:agentix, :turn, {:start, :stop, :halt, :exception}]` family.

## Structured output

Make the model return typed data conforming to a schema instead of free text. Pass a
`:schema` to `Agentix.Conversation.send_message/4` for a one-shot extraction, or set a
`response_format` default on the config for an always-structured conversation.

```elixir
# one-shot, per turn:
schema = [sentiment: [type: :string], score: [type: :float]]
Agentix.Conversation.send_message(id, "I love this!", scope, schema: schema)

# or a conversation-wide default:
Agentix.Conversation.Config.new(model: "...", response_format: schema)
```

A schema is a NimbleOptions keyword or a JSON Schema map — whatever ReqLLM's
`stream_object/4` accepts.

### Reading the object

The parsed object rides on the assistant message's metadata; read it with
`Agentix.object/1`:

```elixir
# from a {:message_completed, ref, message} live event, or Agentix.Chat / a snapshot:
Agentix.object(message)
#=> %{"sentiment" => "positive", "score" => 0.92}
```

In the LiveView layer (`Agentix.Chat`) the most recent assistant message's object is
also projected onto the `:last_object` assign.

### Semantics

* **Resolution** — a per-turn `:schema` wins; `schema: false` opts out of the config
  `response_format` default for one turn; omitting it uses that default (or plain text).
* **Terminal turn** — a schema turn is the answer: the tool loop is skipped even if the
  model emits tool calls (ReqLLM models structured output as a forced tool call).
* **Persistence** — the object is stored in the assistant event's `metadata["object"]`,
  so it survives replay and reconnect with no migration.
* **Recovery** — a per-turn `:schema` override is not persisted; a turn re-run after a
  crash falls back to the config `response_format` default.
