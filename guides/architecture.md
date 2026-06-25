# Architecture

## Process topology

One agent process per conversation. It is a `:gen_statem`, not a `GenServer`,
because a turn is genuinely a state machine and several features (human-in-the-loop
suspension above all) are state transitions rather than flags. States:

- `idle` — no turn in flight.
- `preparing` — running pre-message hooks, assembling and reducing context.
- `streaming` — an LLM turn is streaming via a task.
- `executing_tools` — one or more tool tasks in flight.
- `awaiting_input` — suspended on external resolution (human or client tool).
- `terminating` — shutting down (idle eviction or explicit stop).

Supporting processes: a `Registry` for addressing agents by `conversation_id`, a
`DynamicSupervisor` for spawning them, and `Phoenix.PubSub` for broadcasting live
events to subscribers. The agent knows nothing about LiveView — it publishes to a
per-conversation topic and any number of subscribers consume.

The agent holds only the **working set**, never the full history — see
`07-memory-and-sizing.md`. Footprint is flat in conversation length and linear in
the active agent count.

## Two event planes

There is not one event stream; there are two, with different masters. Conflating
them is the trap behind "the event contract."

- **Canonical events** are written to the log **in-process, synchronously**, as part
  of the agent's transition: `user_msg`, `assistant_msg` (final), `tool_call`,
  `tool_result`, `suspension`, `resolution`. They are the source of truth and must
  never depend on PubSub delivery — a dropped broadcast cannot lose history.
- **Live events** are broadcast over PubSub for observers and include ephemeral
  things never logged: token deltas, thinking deltas, tool progress, state
  transitions. If a subscriber misses them, nothing is lost; durable state is
  reconstructable from the log.

This is why a renderer is *snapshot + live tail* (see `06`): read the log to rebuild
durable assigns on mount, then subscribe to live events for the delta.

## The non-blocking principle

The agent process never blocks on I/O. The LLM stream runs in a monitored task that
sends chunks back as messages; tool calls run in their own monitored tasks and
report results back as messages. The agent's mailbox preserves per-turn ordering,
and because the agent is never parked inside an HTTP call it can always handle
`cancel`, `inspect`, and (later) queued input mid-turn. The only thing that happens
inside the agent's own execution is bookkeeping: append to the log, update the
pending-calls map, broadcast, decide the next transition.

## ensure_started — the unifying door

Callers never hold an agent pid. Everything addresses by `conversation_id` through a
single `ensure_started(conversation_id)` that returns the live process (via its
Registry `via` tuple) or starts it under the `DynamicSupervisor`, rehydrating from
persistence on the way up. Both a new user message and a pending-call resolution
enter through this same door, which is why resumability falls out for free.

## Persisted fsm_state (deliberately small)

```
fsm_state = %{
  state:    :idle | :awaiting_input,   # only ever persisted in these two
  pending:  %{tool_call_id => %{executor, kind, prompt}},
  last_seq: N                          # log position the working set was built from
}
```

`kind` is `:approval | :elicitation | :client_exec` — the discriminator the
renderer switches on (see `06`); executor alone can't distinguish a gated
`:server` call from an elicitation.

There is no persisted `streaming` or `executing_tools` state. This one shape
resolves "what to persist," "which states are safe to evict," and "what a
suspended-on-human agent carries" at once.

Because `suspension` and `resolution` are canonical event types, `fsm_state` is
strictly a **cache over the log** — rebuildable from it, never authoritative. On
any disagreement the log wins. This removes the atomicity problem between the log
append and the snapshot write (the ETS adapter has no transactions).

## Resolved: suspend-safe states and mid-turn kills

Only `idle` and `awaiting_input` are snapshotted and evictable — they are clean. A
kill in `streaming` or mid-`:server`-tool is **not** frozen and resumed; mid-turn
durability is "recover from the log," not "freeze the stream." The two dangling
log shapes recover **differently**:

- **Log ends in a `user_msg`** (killed while streaming, nothing dispatched) —
  re-run the LLM turn. Safe; no side effects happened yet.
- **Log ends in a `tool_call` with no `tool_result`** (killed mid-tool) — do
  **not** re-roll the LLM: it would mint new calls with new ids and re-fire side
  effects (`send_email` twice). **Re-dispatch that exact call, same
  `tool_call_id`.** The library passes the id through; only the user's tool can
  honor it — document loudly that side-effecting `:server` tools should use
  `tool_call_id` as their idempotency key.

## Cancellation

"Stop generating" works from any non-idle state, not only `streaming`:

- From `streaming` — kill the streaming task **and** tear down the HTTP
  connection. ReqLLM's stream response carries cancellation as a captured
  closure, invoked `stream_response.cancel.()` (there is no module-level
  `cancel/1`); verify in tests the socket actually closes. Records a
  cancelled/partial assistant turn.
- From `executing_tools` — `Task.shutdown` the tool tasks and log synthesized
  `"[cancelled]"` tool results so every `tool_call` keeps its paired result —
  providers reject a rendered context with an orphaned call (see `05`).
- From `awaiting_input` — resolve all pending calls as "user cancelled"
  tool-errors. This is also the escape hatch from the single-in-flight composer
  lock: a user parked on an elicitation they don't want to answer cancels the
  turn instead of waiting out the timeout.

## Resolved: idle eviction (two tiers)

- **Short idle, parked in `awaiting_input`** → **hibernate**. Compacts the heap via
  GC while keeping the process alive and addressable, so the human's eventual
  resolution arrives without a DB rehydrate.
- **Long idle** → persist `fsm_state` and **terminate**, dropping from memory.
  Revival through `ensure_started` is cheap, so terminating frees more than
  hibernating holds.

## Concurrent-message policy

v0 is single-in-flight: a user message arriving mid-turn is rejected (the default UI
disables the composer). Post-v0 we expect two caller-chosen modes — direct-send
(interrupt/run-alongside) and queue (serialize). The state machine should handle
"user input arrived in a non-idle state" explicitly per state to leave room for this.

## Crash semantics

A crashing tool task is isolated by its task boundary and surfaces as an error result
fed back to the model, never an agent crash. If the agent crashes, the supervisor
restarts it and it rehydrates from the log via `ensure_started`. The log is the
recovery boundary.

## ReqLLM operational notes (verified v1.16.0)

- Streaming pools are **HTTP/1-only by default** (a known Finch ALPN bug with
  mixed-protocol large bodies) — revisit pool config before chasing streaming
  concurrency at scale.
- Don't reach into ReqLLM struct internals: the substrate already migrated once
  within 1.x (TypedStruct → Zoi). Treat public constructors as the contract.

## Remaining open

- Multi-node addressing (Registry is local; a distributed registry such as Horde or
  syn would be needed for clustering). Out of scope for v0 — the invariant to protect
  is that `ensure_started` stays the *only* addressing point, so this becomes a
  one-file change later.
