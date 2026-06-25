# Rendering

## The tension, and how to resolve it

"100% customizable" and "batteries included" pull in opposite directions. The trap
is resolving that with one big configurable component that takes fifty options — it
always fails to be either. Resolve it with **layers**, borrowing the headless-UI
philosophy.

## Layer 1 — headless (build this first)

A LiveView integration (a `use Agentix.Chat` macro plus an `on_mount` hook) that
owns the conversation assigns and renders *nothing*. It exposes the state and the
verbs; you write your own HEEx.

The mount pattern is **snapshot + live tail** (see `01`), in this order: subscribe
to the live topic first, then fetch the snapshot, then apply. The snapshot is the
canonical log **plus** the agent's in-progress turn state: the agent already
accumulates the streaming text in order to finalize the message, so a mid-stream
mount (second tab, reconnect) fetches the partial text and seeds the JS hook with
it — otherwise the visible message starts mid-sentence. The subscribe-then-fetch
race is benign because the projection is keyed throughout (stream dom-ids,
`tool_call_id`s, last-write-wins `state`): replaying an event already reflected in
the snapshot is a no-op. That idempotence is a property to protect, not an
accident.

### Assigns projection (resolved)

```
%{
  messages:          <LiveView stream of finalized %ReqLLM.Message{}>,
  streaming_message: %{id, thinking} | nil,  # text lives in the JS hook mid-stream
  state:             :idle | :preparing | :streaming | :executing_tools
                     | :awaiting_input,
  streaming?:        boolean,                 # derived from state
  in_flight_tools:   %{tool_call_id => %{name, executor, progress}},
  pending:           %{tool_call_id => %{executor, kind, prompt}}
                     # kind: :approval | :elicitation | :client_exec
}
```

Note what is *not* an assign mid-stream: streaming text. It lives in the JS hook
(see the streaming path below) and only lands in `messages` via `stream_insert` on
finalization. `streaming_message` carries the in-progress id and any thinking
deltas; `streaming?` is derived from `state` and drives both the streaming
indicator and composer-disable.

Helpers it exposes:
- send a user message,
- resolve a pending call (approve/deny, submit an answer),
- cancel the current turn.

This layer is what actually delivers "100% customizable," and it is the one to nail
first, because everything else is optional sugar on top of it.

## Layer 2 — default function components (ownable)

A set of plain function components rendering a clean default chat against that
state: `<.message_list>`, `<.message>`, `<.tool_call>`, `<.composer>`,
`<.thinking>`, plus `<.approval>` and `<.elicitation>` for HITL.

Ship them as **ownable** components — `mix agentix.gen.components` copies the source
into the user's app (the shadcn / Phoenix `core_components.ex` model) so people edit
source rather than fighting config. Function components compose and override far
more gracefully than a monolith.

## Layer 3 — slots

The default components take slots so someone can override just the message bubble,
or just the tool-call card, without rewriting the whole list — e.g.
`<.message_list>` with a `:message` slot that yields the message struct.

## The event contract is the real interface

The renderer is a **projection of the agent's canonical event stream into assigns**.
If the agent publishes a clean, canonical event stream (it does, built on ReqLLM's
`Message` / `ContentPart` / `StreamChunk` types), the renderer is downstream and
swappable. Get the contract right and the UI is trivial to replace; get it wrong and
every renderer leaks provider quirks.

These are the **live events** (the PubSub plane from `01` — ephemeral, lossy-safe,
never the source of truth). Keep the union closed and small: Elixir 1.20 offers
only inference-based redundant-clause warnings (no user-declared sum types, no
exhaustiveness checking — that's milestone 3, ~1.22), so a checkable declared
union is a future upgrade, not a v0 tool:

```
{:state_changed, state}
{:turn_started, turn_ref}
{:text_delta, turn_ref, msg_id, chunk}            # → JS hook, not assigns
{:thinking_delta, turn_ref, msg_id, chunk}
{:message_completed, turn_ref, %ReqLLM.Message{}} # → stream_insert
{:tool_call_started, tool_call_id, name, executor, args}
{:tool_progress, tool_call_id, payload}           # progressive tools
{:tool_call_resolved, tool_call_id, result}
{:tool_call_errored, tool_call_id, reason}
{:suspended, tool_call_id, executor, prompt}      # awaiting human/client
{:turn_completed, turn_ref} | {:cancelled, turn_ref}
```

Each event maps cleanly to an assign mutation: `:state_changed` sets `state`
(and derives `streaming?`); `:text_delta`/`:thinking_delta` push to the JS hook;
`:message_completed` does `stream_insert`; the `:tool_call_*` events maintain
`in_flight_tools`; `:suspended` adds to `pending` and its resolution clears it.

## Executor-aware rendering

The tool `executor` (see `03`) drives what the UI shows for a tool call:
- `:server` — a tool-call card with result, and progress if the tool is progressive.
- `:human` — an elicitation form/prompt; the submitted value resolves the call.
- gated (`:requires_approval`) — a confirm card; approve/deny resolves the gate.
- `:provider` — a "searched the web" style affordance; the result arrives in-stream.
- `:client` — usually executes invisibly; the result returns over the socket.

The discriminator the components actually switch on is `pending[id].kind`
(`:approval` / `:elicitation` / `:client_exec`), not the executor — executor alone
can't distinguish a gated `:server` call from an elicitation, and a gated
`:client` call suspends twice (approval, then client execution — see `03`).

## The streaming token path (the one real perf concern)

Appending tokens by re-rendering the streaming message server-side makes LiveView
re-diff a growing string every chunk. The fix: push token deltas to a small JS hook
via `push_event` and let the client append to the DOM, updating server assigns only
on finalization. Markdown is rendered live, client-side (a settled non-issue), so
the hook owns both append and render during streaming; the server holds the
finalized message.

The message *list* uses `Phoenix.LiveView.stream/3` so the list itself isn't
re-diffed; the single in-progress message is the only thing the JS hook manages
incrementally.

## Resolved decisions

- **Event union + assigns shape** — pinned above. The contract is the live event
  union (this doc) plus the canonical log for snapshot/scrollback (`01`, `04`).
- **Client-tool dispatch** (see `03`) — `:client` is `:human` with JS as the "user."
  The agent emits `{:suspended, id, :client, args}`; a registered JS hook maps tool
  name → client function, executes it, and `pushEvent`s the result back, which calls
  the same `resolve` as any other pending call. Often invisible (no prompt rendered).
  Security: the server validates `:client` results and never trusts one for a
  privileged decision.
- **Approval vs elicitation** — **two components, one mechanism.** The resolution
  path is identical, so the headless layer has one `pending` concept and one
  resolver, but ship both `<.approval>` (boolean gate) and `<.elicitation>`
  (arbitrary form) — don't force a form abstraction over a yes/no.
