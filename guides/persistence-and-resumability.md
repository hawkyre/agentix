# Persistence and resumability

## Pluggable behaviour

Persistence is a behaviour with two shipped adapters: an ephemeral/ETS default for
people who don't want a database, and an Ecto/Postgres adapter for durable,
resumable conversations. The framing is Oban-style: an append-only, ordered,
queryable log is the source of truth.

ReqLLM's `Context`, `Message`, and `ContentPart` structs all implement
`Jason.Encoder`, so **writes** to `jsonb` are free. Reads are not: ReqLLM
(verified v1.16.0) has no public JSON→struct decode path — `Response.decode_*`
decodes provider wire payloads, not persisted JSON. Agentix owns a small
deserializer for those three structs (worth offering upstream); budget for the
content-part variants and tool-call-args edge cases there.

The ETS table in the default adapter is owned by a supervisor-side owner process
(or is a named public table) — never by the agent, or kill-and-resume dies with
the very process it is supposed to survive.

## Schema (sketch)

```
conversations
  id              uuid pk
  settings        jsonb        -- provider/model/system prompt snapshot
  fsm_state       jsonb        -- the persisted machine state (see below)
  status          enum         -- active | suspended | idle | ended
  inserted_at / updated_at

events                          -- append-only, ordered by per-conversation seq
  id              uuid pk
  conversation_id uuid fk
  seq             bigint       -- monotonic per conversation
  type           enum          -- user_msg | assistant_msg | tool_call
                                --  | tool_result | suspension | resolution
  content         jsonb
  inserted_at

summaries                       -- derived compaction artifacts; double as snapshots
  id              uuid pk
  conversation_id uuid fk
  from_seq        bigint        -- span of events this summary covers
  to_seq          bigint
  content         jsonb
  version         text
  inserted_at

tool_calls                      -- so HITL suspensions survive a kill
  id              text pk       -- the tool_call_id (correlation key)
  conversation_id uuid fk
  executor        enum
  status          enum          -- pending | resolved | errored | expired
  args            jsonb
  result          jsonb
  inserted_at / resolved_at

model_calls                     -- OPTIONAL audit, off by default (see below)
  id              uuid pk
  conversation_id uuid fk
  turn_ref        bigint
  rendered_context jsonb        -- exactly what was sent to the model
  model           text
  usage           jsonb
  latency_ms      integer
  summary_version text          -- which compaction summary applied
  evictions       jsonb         -- what was stubbed/evicted this turn
  inserted_at
```

The `events` table is the canonical log. `tool_calls` is partly derived but kept
separate because its row-level mutable status (pending → resolved) is exactly what a
revived agent needs to reconstruct in-flight suspensions.

`summaries` is derived, never canonical (compaction must not touch the log — see
`05`), but it is load-bearing: revival reads "latest summary + events after its
`to_seq`," and the summarization reducer's state ("latest summary covers up to seq
N") is derived from this table rather than carried loose.

## Kill-and-resume

Both a new user message and a pending-call resolution enter through
`ensure_started(conversation_id)` (see `01`), so revival is automatic: kill the
agent on idle, and the next event of either kind starts it back up and rehydrates
from the log.

What you persist is **not just the message log**. A revived agent must also know it
was suspended on a human and which calls are still pending — so the `fsm_state`
snapshot carries the current state and the `pending` map. Reconstruct in-flight
`tool_calls` from their rows. Without this, a revived agent comes back not knowing
it owes the model a tool result.

### Resolved: the `fsm_state` payload shape

The persisted snapshot is deliberately small (the canonical definition lives in
`01`):

```
fsm_state = %{
  state:    :idle | :awaiting_input,   # only ever persisted in these two
  pending:  %{tool_call_id => %{executor, kind, prompt}},
  last_seq: N                          # log position the working set was built from
}
```

`last_seq` is what lets revival read "latest summary + events since that summary's
span" instead of replaying from zero (see snapshot cadence below). This one shape is
the join between the resolver (`03`), the kill/resume path, and the schema. And
because `suspension`/`resolution` are canonical event types, `fsm_state` is strictly
a **cache over the log** — rebuildable, never authoritative; on disagreement the log
wins (canonical statement in `01`).

Safe-to-suspend states: `idle` and `awaiting_input` are clean to snapshot and
evict. `streaming` and mid-`:server`-tool are not — there is no persisted
`streaming` or `executing_tools`. A kill in those states is **not** frozen and
resumed; recovery is from the log, and the two dangling shapes differ: a log ending
in a `user_msg` re-runs the LLM turn (safe — no side effects yet); a log ending in a
`tool_call` with no `tool_result` **re-dispatches that exact call with the same
`tool_call_id`** — never re-rolls the LLM, which would mint new ids and duplicate
side effects (canonical statement in `01`). Idempotency on `tool_call_id` also
covers the kill → revive → late-answer race.

## Timeout machinery

Suspension timeouts belong to the **persistence behaviour** (`schedule_expiry` /
`cancel_expiry`), not to core machinery — a per-agent timer dies with the agent,
and Oban cannot be a core dependency when persistence is pluggable (Oban requires
Ecto/Postgres; the default adapter is ETS). The Ecto adapter backs expiry with Oban
jobs ("expire pending tool call X if still unresolved"), which survive kill/revive.
The ETS adapter uses `Process.send_after` best-effort — acceptable, since ETS
doesn't survive a restart anyway. Oban stays an optional dep of the adapter, not of
Agentix.

## Resolved: scope on revival

`%Agentix.Scope{}` is runtime ambient state (current user, db handle) and is not
persisted. It is supplied **per entry call**: a LiveView resolution passes its own
scope; a webhook or job passes what it has. Timeout-driven resolutions (the expiry
job) run with a documented **system scope** — a tool that needs a real user scope
and receives the system scope fails as a tool-error rather than guessing. Apps that
need more can stash a serializable scope seed in `conversations.settings`, but that
is app-level composition, not library machinery.

## Context vs message storage

The principle that resolves the "store them together?" question: **the message log
is canonical; the rendered context is derived.**

- Messages (what the user said, what the model said, tool calls and results) are
  always logged. They define the logical conversation and are what replay
  reconstructs.
- The resolved context a hook injects for a given turn (retrieval hits, memory) is
  a per-turn artifact — a function of the message plus external state at that
  instant. It does **not** go in the message history. Storing it inline conflates
  "what the user said" with "how we happened to augment that turn," bloats the
  canonical record, and lies on replay, because re-running the conversation should
  generally re-derive fresh context, not resurrect a stale snapshot.

So: messages always logged; resolved context logged **separately and optionally**,
keyed by turn, in `model_calls`. That optional table is also where summarization
version and evictions land (see `05`), so that when someone reports "it forgot the
address I gave it," you can tell whether it was compacted out or the model ignored
it. The tradeoff "optional" buys is reproducibility: without recording exactly what
was rendered, you cannot perfectly reconstruct why the model said what it said —
valuable for evals and debugging, but it costs storage and has privacy
implications, so it is off by default and switched on when evaluating.

## Resolved: snapshot cadence

**Event-sourced truth + snapshots as an optimization — and the compaction summaries
*are* the snapshots.** Pure replay-from-zero gets slow on long conversations;
snapshot-only loses auditability. But the prefix summaries compaction already
produces (see `05`) are prefix snapshots of the conversation, keyed by the span of
events they cover. So revival reads "latest summary + events since its span" (using
`fsm_state.last_seq`) rather than replaying everything. One mechanism serves both
compaction and snapshotting — no separate snapshot table or cadence to tune.

## Resolved: `model_calls` GC

TTL-based, configurable, **off by default.** It is the fastest-growing, least-
permanent table and exists only for debugging/evals, so a simple time-based drop (or
a per-conversation row cap) is enough. Since the audit table itself is off by default
(below), there is usually nothing to GC; when it is switched on for an eval run, the
TTL keeps it from growing without bound.

## Open questions

- Multi-node persistence story (follows the addressing question in `01`; out of
  scope for v0).
