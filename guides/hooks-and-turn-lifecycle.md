# Hooks and the turn lifecycle

## The turn as a pipeline

A turn runs as a pipeline; the mental model to steal is Plug. Each hook receives the
accumulated state and returns continue/halt, and the runtime threads them in order.
Two hook surfaces run at different points, plus one optional surface on the token
stream.

## The hook context object — `%Agentix.Turn{}`

Hooks (and `:server` tools) receive and return a thin struct, not a bare ReqLLM
`Context`:

```
%Agentix.Turn{
  context:      %ReqLLM.Context{},   # the conversation so far
  user_message: %ReqLLM.Message{},   # the message that opened this turn
  turn_ref:     term,                # correlates live events + audit
  scope:        %Agentix.Scope{}     # Phoenix 1.8 Scope-style: current_user, etc.
}
```

`scope` is where ambient state lives, so `:server` tools get their context argument
from the same place hooks do — one mechanism, not two.

## Pre-message hooks (injection)

Run after a user message arrives, before the model is called. Each returns
`{:cont, turn}` or `{:halt, reason}`. This is the "inject context based on the user
message" requirement: a hook does retrieval, pulls memory, or appends `ContentPart`s
for this turn only.

### Resolved: concurrency — ordered list with an opt-in parallel group

Default to an ordered pipeline (predictable). A hook may be declared in a parallel
batch when it is independent, so retrieval calls that each do I/O don't serialize
their latency before the first token. **No dependency DAG** — that's overengineering
for v0; ordered-with-parallel-groups covers nearly everything.

**Merge rule for parallel batches:** concurrent hooks can't thread the turn, so
they are **append-only** — each returns ContentParts to add, merged in declaration
order; they may not otherwise mutate the turn. Mutation stays exclusive to ordered
hooks. Without this rule, "what does a parallel group return" becomes an
implementation-time argument.

### Resolved: tool-availability mutation — deferred to v0.1

Letting a hook change the tool list per turn is powerful but the tool list is part of
the cacheable prefix, so per-turn mutation fights prompt caching and complicates the
type model. v0: tools are fixed per agent config.

## Post-message hooks

Run after the assistant turn resolves: persistence, triggering async summarization,
memory write-back, guardrail checks. A guardrail that rejects an output and requests
a regen is a transition back into a model call — design it as an explicit loop with a
bounded retry count, not unbounded recursion.

## Stream-transformer hooks (optional, hot path)

A hook on the token stream itself: redaction, PII scrubbing, citation parsing. The
hardest surface (it runs in the hot path), but design the seam now even if
unimplemented in v0 — retrofitting it later means re-plumbing the streaming path.

## Durable vs transient output

The key property a hook declares: is its output **durable** (joins the canonical log,
future turns depend on it) or **transient** (per-turn scaffolding, re-derivable)?

- A retrieval hook is transient — augmentation for this turn only, not in the message
  history. At most it lands in the optional audit record (see `04`).
- A hook writing a running summary, or appending a tool result later turns read, is
  durable history and joins the log.

Same pipeline, two destinations, decided by a flag on the hook rather than by where in
the code it runs. Keeps "where does this get stored" next to the thing that knows.

## Relationship to compaction: none

Injection (pre-hooks) and reduction (compaction, see `05`) are **independent
subsystems** — no shared mechanism, trigger, or data flow. A pre-hook adds per-turn
augmentation; compaction evicts from the window. The library must not couple them.

The **only** shared thing is the token budget, computed once over the final rendered
context after both have run. If someone writes a retrieval hook that happens to read
compaction's summary output, that is application-level composition they assemble —
not something Agentix wires together.

Two rules at the seam (full layout rationale in `05`):

- **Overflow** — reduction targets `budget − injection_reserve`. A hook whose
  injected content blows the reserve is a loud per-hook error, never a silent
  truncation: compaction has already run and is not re-entered after hooks.
- **Placement** — injected per-turn content goes at the **tail**, adjacent to the
  user message. Never before the history: that invalidates the provider cache
  prefix every turn and undoes prefix-ward compaction (see `05`).

## Resolved decisions recap

- Concurrency: ordered pipeline + opt-in parallel groups, no DAG. Parallel
  batches are append-only (ContentParts merged in declaration order).
- Tool-availability mutation: deferred to v0.1; tools fixed per agent in v0.
- Context object: `%Agentix.Turn{}` carrying context, user_message, turn_ref, scope.
