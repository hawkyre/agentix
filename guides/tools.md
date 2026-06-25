# Tools

## One tool, two orthogonal axes

A tool is declared once. What varies is captured on two independent axes, not one,
because "needs human input" and "server handles it" are two different questions
tangled together.

1. **Executor** — who produces the result.
2. **Approval gate** — whether the call is gated by human confirmation before it runs.

These are independent. A server tool can be gated (`send_email` runs server-side but
needs a confirm click first) or ungated. Confirmation is not a kind of tool; it is a
gate in front of an otherwise-server tool. "Answering," by contrast, is a tool whose
*result is* the human's input — a different control flow entirely.

## Executor axis

- `:server` — your code runs it and returns a result. The default.
- `:human` (elicitation) — the human *is* the executor; their answer is the result.
  The agent suspends. One-phase: nothing runs after the human responds.
- `:client` — runs in the browser/LiveView: geolocation, client/device state, a file
  picker, a client-side computation. Not a human decision and not the server. The
  execution boundary is the socket; only works while one is live.
- `:provider` — the *provider* executes it (hosted web search, code interpreter) and
  the result returns in the stream. Pass it through, **do not** dispatch locally.
  Already in the stack via ReqLLM's provider-hosted tools.

`:sub_agent` is deferred — it is `:server` with a spawn inside; modelling it as a
distinct executor adds complication for no gain.

## Approval gate (orthogonal modifier)

A policy on side-effecting tools: `:auto` or `:requires_approval`. Two-phase:
suspend → human approves → the tool then executes → result. Distinct from `:human`
elicitation, which is one-phase.

**Legal matrix:** the gate applies to **`:server` and `:client` only**.
`:provider` cannot be gated — the provider executes mid-stream; there is no
pre-execution suspend point. Gating `:human` is circular (approve asking the
human?) — reject it at definition time. A gated `:client` call suspends **twice**:
once for approval, once for client execution — two pending entries, two
resolutions.

## Progressive tools (a property, not a type)

A tool emitting intermediate progress before a final result (a long server job
streaming logs) is marked `:streaming?`. Orthogonal to the executor — it affects the
renderer (show progress) and whether the call resolves as one event or many.

## Tool definition (sketch)

```
name:             string
description:      string
parameter_schema: NimbleOptions keyword list, passed through to ReqLLM
executor:         :server | :human | :client | :provider
approval:         :auto | :requires_approval
streaming?:       boolean
retention:        see 05-compaction (per-tool age/count + never_evict)
callback:         required for :server (and the post-approval phase of gated tools)
```

`:server` callbacks receive parsed args plus the `%Agentix.Turn{}` scope (see `02`)
for ambient context (current user, db handle).

**Schema pass-through, not a new layer.** ReqLLM's `Tool.new/1` already natively
accepts NimbleOptions keyword lists (and raw JSON Schema) and compiles them to JSON
Schema itself (verified v1.16.0). Agentix hands the schema through verbatim — it
must not re-compile or re-validate, or schemas get double-compiled and the two
interpretations drift.

## The control-flow collapse

From the state machine's point of view every executor reduces to one of two shapes:

- **Resolve-in-process**: `:server`, and `:provider` (resolves in-stream).
- **Suspend-and-await-external-resolution**: `:human`, `:client`, anything gated,
  and (later) `:sub_agent`.

So you build *one* suspension primitive; the executor only parameterizes who may
resolve and how the UI prompts. The distinction stays explicit where it matters (tool
declaration, loop dispatch, renderer) without multiplying machinery.

## The suspension/resolution primitive

A suspended call is a pending tool call with a correlation id (`tool_call_id`) and a
resolver. A single turn can carry a **mix** — three tool calls, two `:server`
(self-resolve in ms) and one `:human` (resolves whenever). `awaiting_input` means
"awaiting resolution of N pending calls, some already done." The agent holds:

```
pending: %{tool_call_id => status}   # :running | :awaiting | :resolved | :errored
```

The resume to the next LLM turn fires only when the pending set empties.

Two related-but-distinct shapes share the name "pending" — keep them straight:

- This **in-memory tracking map** holds *every* call in the turn with its status,
  including `:running` `:server` calls. It is the agent's working state for deciding
  when to resume; it is never persisted as-is.
- The **persisted/rendered `pending`** (`fsm_state.pending` in `01`/`04`, the
  renderer assign in `06`) is only the *awaiting-external* subset, shaped
  `%{tool_call_id => %{executor, kind, prompt}}` where `kind` is
  `:approval | :elicitation | :client_exec` — the field the renderer actually
  switches on. Running `:server` calls are not in it —
  if the agent is killed mid-turn, those are recovered by re-running from the log
  (the `tool_call` with no `tool_result`), not from the snapshot. The renderer shows
  running calls via `in_flight_tools`, awaiting ones via `pending`.

### Resolver interface

```
:gen_statem.call(via(conversation_id), {:resolve, tool_call_id, result})
```

`call`, not `cast`, for the synchronous ack — a confirm click that silently vanishes
is a terrible HITL failure mode. The agent:

1. Validates `tool_call_id` against the pending set; if stale, unknown, or already
   resolved, replies `{:error, :stale}` (covers double-clicks, resubmits, expiries).
2. Records the result, **replies `:ok` immediately**.
3. *Only then*, via an internal `:next_event`, decides whether to start the next turn.

Replying before resuming is essential: resume-first blocks the caller for the whole
next turn and trips the 5s call timeout.

### Addressing and revival

The caller never holds the agent pid. It resolves through
`ensure_started(conversation_id)`, which returns the live process or starts/rehydrates
one, then calls. This is what lets a suspended-on-human conversation survive the agent
being killed: the answer arriving revives it.

Resolution is a **public API**, not a socket affordance: anything holding a
`conversation_id` and a `tool_call_id` — a LiveView, a webhook controller, a job, an
external system — calls the same `resolve`. This is what generalizes the suspension
primitive from HITL chat into durable workflows (see `08`).

### Timeout and idempotency

Every suspending call needs a timeout. Default: resolve an unanswered call to a
tool-error result the model can recover from ("user did not respond"). Idempotency
keyed on `tool_call_id` covers the kill → revive → late-answer race — and the same
id is the idempotency key side-effecting tools should honor, because a kill
mid-`:server`-tool is recovered by re-dispatching that exact call (see `01`).
Timeout machinery is owned by the persistence adapter (`schedule_expiry` /
`cancel_expiry` — see `04`) rather than a per-agent timer, since a per-agent timer
dies with a killed agent.

## Resolved: `:client` is `:human` with JS as the "user"

The agent emits `{:suspended, id, :client, args}`; a registered JS hook maps tool name
→ client function, executes, and `pushEvent`s back to the LiveView, which calls the
same `resolve`. Mechanically symmetric to elicitation, just no visible prompt.

**Security rule (write it down):** client results are user-controllable. The server
validates them and **never trusts a `:client` result for a privileged decision.**

Two edge rules: with **no live socket** (headless/API callers) a `:client` call
fails fast to a tool-error after a short grace period — it must not park the
conversation in `awaiting_input` forever. With **multiple sockets** (two tabs)
both execute the JS; the second `resolve` gets `{:error, :stale}` server-side, but
client-side double side effects (two file pickers) are the app's to guard.

## Resolved: approval vs elicitation — one mechanism, two components

The resolution path is identical (`{:resolve, tool_call_id, result}`), so the headless
layer has one `pending` concept and one resolver. But ship **two** default components
(see `06`): `<.approval>` (a boolean gate) and `<.elicitation>` (an arbitrary form).
Don't force a form abstraction over a yes/no.

## Who consumes the executor field

- **The loop** — dispatch: run, suspend, or pass through.
- **The renderer** — `:human` → elicitation form; gated → confirm card; `:provider`
  → "searched the web" affordance; `:client` → execute (often invisible); `:server`
  → tool-call card with result/progress.
- **Persistence / replay** — the `tool_calls` table tracks executor and status so
  suspensions survive a kill.

## Result convention

Structured results carry model-visible semantics in the content body as JSON —
`%{ok: true, result: ...}` / `%{ok: false, error: ...}` — following ReqLLM, so
follow-up turns don't depend on adapter-only metadata.
