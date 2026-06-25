# Compaction

## Principle

Compaction operates on the **rendered context, never on the canonical log**. The
log is immutable history; compaction is a projection over it — a function from the
full event log to "the subset/summary that fits the budget." This rules out the
tempting but wrong implementation of editing the message history in place, which
would corrupt replay and conflate "what happened" with "what we sent."

## Compaction and injection are independent

Reduction (compaction) and injection (pre-hooks, see `02`) are separate subsystems
with separate interfaces, triggers, and data flow. They are not two halves of one
loop. The only thing they share is the **token budget**, computed once over the
final rendered context after both have run. Nothing else connects them. The library
must not couple them.

Two rules at the seam (stated from the hook side in `02`):

- **Overflow** — reduction targets `budget − injection_reserve`; an injection that
  blows its reserve is a loud per-hook error. Compaction is never re-entered after
  hooks run.
- **Layout of the rendered context** — cache-prefix discipline applies to the whole
  assembly, not just compaction: stable prefix (system prompt + latest summary) →
  verbatim history tail → per-turn injected content adjacent to the user message at
  the very end. Injected content placed before the history would invalidate the
  provider cache prefix every turn.

## Reduction is a pipeline of reducers

Compaction is not one strategy; it is a pipeline of independent reducers run
cheap-to-expensive, each with its own config and trigger. The trigger logic is:
run the free deterministic reducers always; if still over budget, summarize the
overflow. This is cost-minimizing by construction — you never pay for a
summarization call you didn't need, and in most tool-heavy conversations the
tool-result reducer alone keeps you under budget so summarization never runs.

### 1. Tool-result retention (first-class)

The fattest target and the first thing to cut — a single large API response dwarfs
the whole dialogue. This is a first-class reducer, not a sub-case of summarization,
with two retention modes that map to different tool shapes:

- **Age-based** — keep the full result for K turns, then it expires. Good default.
- **Count-based** — keep the last N results from *this tool*, older ones expire.
  The right mode for repeatedly-called tools (search, `read_file`) where only the
  recent calls matter.

Declared per-tool with a global default (a weather lookup and a 50KB document have
different lifespans), plus a `never_evict` flag for results that are durable facts.
Deterministic, no model call, runs every assembly. (Unit: turns rather than
messages — a turn is the natural span a result stays relevant.)

**Constraint — pairing.** A tool call and its result are a *pair* in the canonical
format, and providers reject a history with an orphaned call or result. So eviction
must not drop a result and leave the call dangling. It **stubs** the result content
(`[result expired]`) while keeping the pairing intact. Stubbing also signals to the
model that the call happened, so it doesn't re-issue it. (All of this is on the
rendered context; the log keeps the real result forever.)

### 2. Sliding window on dialogue

A turn or token cap on plain dialogue. Deterministic, no model call.

### 3. Summarization

The only expensive, lossy, model-calling reducer. It fires **only if** the free
reducers above didn't reach budget. Two rules:

- **Off the critical path.** Don't block the next user turn on a summarization call.
  Summarize asynchronously between turns and write the result as a derived artifact
  keyed by the span of events it covers (the `summaries` table — schema in `04`). Context assembly then always just reads
  "latest applicable summary + verbatim tail," and a revived agent reconstructs
  context from the log plus those artifacts — no special `compacting` state, and
  compaction stays entirely out of the suspend/resume path. (If you ever do inline
  blocking summarization as a fallback, *then* you need a state and persisted
  progress — which is itself the argument against doing it inline.)
- **Prefix-ward, for cache safety.** Providers cache on a stable prefix. Rewriting
  the *middle* of the context invalidates the cache for everything after the edit
  and makes you pay full price on the recent tokens you were trying to keep cheap.
  So only ever collapse the *oldest* span into a summary at the front, leave the
  tail byte-stable, and recompact in discrete chunks rather than trimming
  continuously. Continuous trimming of recent context is the worst case for cost;
  chunked prefix collapse is the best.

## Reducer interface (sketch)

```
reduce(context, budget, state) -> {context, state}
```

The pipeline threads a shrinking budget through reducers in order. Each returns the
reduced context and any state it needs to carry (e.g. the summarization reducer's
"latest summary covers events up to seq N").

## Token counting

Pre-send counting is approximate — exact counts only come back after the call, and
tokenization is model-specific. Trigger on an estimate (a real tokenizer like
tiktoken for OpenAI, a char/4 heuristic elsewhere) with a safety margin. Budget
conservatively: an over-budget request is a hard failure, an over-eager compaction
is just mild waste.

## Observability

The optional `model_calls` audit record (see `04`) carries which summary version
and which evictions applied to each turn. Since compaction is lossy and the classic
cause of "the agent forgot," this record is how you prove whether something was
compacted out or the model just ignored it. Cheap to record now, miserable to add
later.

## Resolved: budget shape (hybrid, phased)

The model is a hybrid, not a single-vs-per-tier either/or:

- A **single total budget** is the hard ceiling — it guarantees you never overflow,
  full stop. This is the v0 surface.
- **Optional per-tier caps** (e.g. "tool results ≤ 30% of the window") are guards
  that trigger earlier eviction so one fat tool result can't starve dialogue. For a
  tool-centric library this guard earns its config surface — but it is **deferred to
  v0.1**, added when a real workload misbehaves. Single-total-only is a defensible
  v0.

The reducer interface must stay forward-compatible with per-tier caps: the budget
threaded through reducers is a value that can later carry per-tier sub-limits
without changing the `reduce/3` signature. That is the one thing to get right now so
adding caps in v0.1 is not a breaking change.

> If a real tool-heavy workload starves dialogue before v0.1, promote the per-tier
> cap early — it is additive, not a redesign.
