# Memory model and sizing

This is the through-line that ties the agent, persistence, compaction, and
rendering together. The core rule: **the agent holds the bounded working set; the
log holds everything; the renderer reads the log for scrollback.** Conflating these
is what would quietly turn every agent into a memory hog.

## Three stores, two of them not in the agent

- **The working set (in memory, bounded).** What the agent keeps: the small
  `fsm_state`, the rendered context for the active turn (already bounded — it's what
  compaction produces: latest summary + verbatim tail + retained/stubbed tool
  results, under budget), a short tail of recent finalized messages so it can
  assemble the next turn without a DB round-trip, and the in-progress assistant
  text it accumulates mid-stream (it finalizes the message from this buffer and
  serves it to mid-stream mounts — see `06`). The agent never holds message 1
  through 4,000 in memory.
- **The log (on disk, unbounded).** The `events` table is the only unbounded store
  and the source of truth: every message, the *real* tool results (not the stubs),
  every suspension and resolution. The agent reads from it lazily — on revival it
  reconstructs the working set from "latest summary + events since that summary's
  span," not by loading everything.
- **Scrollback (renderer, reads the log).** When a user scrolls up to a message
  long since compacted out of the working set, the headless layer paginates
  `events` backward. The UI shows the whole conversation; the agent only ever holds
  the working set.

There is exactly one unbounded store and one bounded store. No third copy, no
"agent's idea of history" drifting from "the log's idea of history." The rendered
context the agent keeps and the thing it sends the model are the *same* bounded
object, a projection of the log.

Consequence: agent footprint is **flat in conversation length** and **linear in the
active agent count** (managed by eviction), not in total history.

## User sees the log; the model sees the projection

A deliberate, correct divergence: scrolling up shows the true historical message
from the log; the model gets the compacted projection. They answer different
questions ("what was said" vs "what fits the budget"). The practical upshot is a
debugging rule: when chasing "why did it forget X," pull from `model_calls` (what
was actually rendered to the model that turn), not from what's on screen. That's
what the optional audit table is for.

## Sizing: bound by tokens, not message count

"Keep N messages" is the wrong knob — one 50 KB tool result is worth ~200 chat
messages. The working set is bounded by a **token budget**, and message count
floats under it.

Conversion at ~4 bytes/token and a mixed average of ~200 tokens/message:

| Working budget | ≈ messages |
|----------------|-----------|
| ~16K tokens    | ~80       |
| ~32K tokens    | ~160      |
| ~64K tokens    | ~320      |

Default planning number: **~30K-token working window ≈ 100–150 chat messages.**
Tool-heavy conversations hold fewer distinct events but more tokens each — except
the retention reducer stubs old tool results down to ~10 tokens, so many stubbed
pairs cost almost nothing and the count can run higher.

## When compaction triggers

Two triggers; for a tool-centric agent the cheap one dominates:

- The deterministic reducers (tool-result retention, sliding window) run on **every**
  assembly — they're free, so they're never gated.
- Expensive summarization fires only when the verbatim tail exceeds the **working
  budget** — a cost knob set well below the model ceiling, since every context token
  is re-billed every turn. Default working budget ~25–50K tokens; hard ceiling
  ~70–75% of the model window as the never-exceed guard that approximate
  token-counting's safety margin protects.

## Memory per gen_statem

Text content lives in **refc binaries**: anything over 64 bytes (essentially every
message) goes to the shared binary heap as a ref-counted binary, so the process
heap holds a ~56-byte pointer, not the bytes. The dominant cost is binary, and if
the working set is kept as a `ReqLLM.Context` of message structs (not a
pre-concatenated prompt string), the same binaries are shared between the message
list and the assembled context rather than duplicated.

For a ~32K-token chat working set (~160 messages):

| Component                         | ≈ size            |
|-----------------------------------|-------------------|
| Text binaries (refc, shared heap) | ~128 KB           |
| Struct skeletons (~160 × ~300 B)  | ~50 KB            |
| `fsm_state` + gen_statem baseline | ~5–10 KB          |
| **Live data**                     | **~180 KB**       |

Typical **150–250 KB** for an active chat agent. Between GC sweeps RSS runs
~1.5–2×, so budget ~300–400 KB. Tool-heavy with a few large *recent* results still
in full (say 3 × 6K tokens before they age out) adds ~70 KB plus cheap stubs →
**~300–600 KB**.

Scaling sanity check (text isn't shared across conversations, so it's linear in the
active set):

| Active agents | ≈ memory |
|---------------|----------|
| 1,000         | ~200 MB  |
| 10,000        | ~2 GB    |

Which is exactly why eviction to the log earns its keep, and why footprint must stay
flat in length.

## Constraints this imposes (honor from day one)

- **Keep the working set as `ReqLLM.Context`, never a concatenated prompt string.**
  Concatenating doubles the footprint and breaks binary sharing.
- **Keep the in-memory message struct lean.** Per-turn usage, latency, and audit go
  to `model_calls` on disk, not into the in-memory struct — otherwise every process
  carries data only the debugger wants.
- **Hibernate before evicting.** See `01` — hibernate compacts the heap for agents
  parked in `awaiting_input`; full idle terminates and persists to the log.
