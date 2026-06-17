// Agentix streaming + markdown hooks.
//
// Renders the in-progress assistant message incrementally on the client so the
// server never re-diffs a growing string. Both the response text and the model's
// thinking stream this way. Attach `AgentixStream` to the element that wraps the
// streaming message, give it `phx-update="ignore"` (its content is client-owned)
// and a `data-msg-id`, and give it two child nodes the hook writes into:
//
//   <div id={"agentix-stream-#{@streaming_message.id}"} phx-hook="AgentixStream"
//        phx-update="ignore" data-msg-id={@streaming_message.id}>
//     <div data-agentix="thinking"></div>
//     <div data-agentix="text" data-markdown="true"></div>
//   </div>
//
// The server pushes two events per kind ("text" | "thinking"):
//   * "agentix:seed"  — %{id, kind, text, seq}: content + delta count so far, on a
//                       mid-stream (re)connect
//   * "agentix:delta" — %{id, kind, chunk, seq}: each streamed token
// `seq` is a per-message counter; a delta whose seq is below what's applied is dropped,
// so a reconnect during an active stream never double-renders.
//
// ## Markdown
//
// Message text renders as markdown by default. A library can't ship a markdown engine
// (it would force the dep on headless/API hosts), so the host wires one once:
//
//   import { marked } from "marked"
//   import DOMPurify from "dompurify"
//   import { AgentixStream, AgentixMarkdown, AgentixComposer, configureMarkdown } from "agentix/..."
//   configureMarkdown((raw) => DOMPurify.sanitize(marked.parse(raw)))
//
// Without `configureMarkdown`, both hooks fall back to plain text — so the default is
// safe and inert until a renderer is provided. The renderer MUST sanitize (model output
// is untrusted). The `data-agentix="text"` node opts in via `data-markdown` (≠ "false");
// the `thinking` node is always plain text.

let markdownRenderer = null

// Wire a `(rawText) -> safeHTML` renderer (e.g. marked + DOMPurify). Module-level: one
// renderer per page (shared across LiveSocket instances — a known, acceptable limitation).
export function configureMarkdown(fn) {
  markdownRenderer = fn
}

// Rendered HTML when a renderer is configured, else null (caller falls back to text).
function renderMarkdown(raw) {
  return markdownRenderer ? markdownRenderer(raw) : null
}

export const AgentixStream = {
  mounted() {
    // Next-accepted seq per kind; a delta below it is a duplicate already rendered.
    this.seq = { text: 0, thinking: 0 }
    // Own the raw text per kind: with markdown the node holds HTML, not raw text, so we
    // can't append chunks to it — we re-render the whole buffer each frame instead.
    this.raw = { text: "", thinking: "" }
    this.rafPending = { text: false, thinking: false }

    this.handleEvent("agentix:seed", ({ id, kind, text, seq }) => {
      if (id !== this.msgId()) return
      this.raw[kind] = text || ""
      this.seq[kind] = seq || 0
      this.schedulePaint(kind)
    })

    this.handleEvent("agentix:delta", ({ id, kind, chunk, seq }) => {
      if (id !== this.msgId() || seq < this.seq[kind]) return
      this.raw[kind] += chunk
      this.seq[kind] = seq + 1
      this.schedulePaint(kind)
    })
  },

  // Coalesce bursts of deltas into one paint per animation frame; the guard flag stops
  // multiple rAFs queuing so the latest buffer always wins and none is dropped.
  schedulePaint(kind) {
    if (this.rafPending[kind]) return
    this.rafPending[kind] = true
    requestAnimationFrame(() => {
      this.rafPending[kind] = false
      this.paint(kind)
    })
  },

  paint(kind) {
    const node = this.node(kind)
    if (!node) return
    const raw = this.raw[kind]
    if (raw) node.hidden = false

    // The text node renders markdown when a renderer is wired and it opts in; the thinking
    // node is always plain text.
    if (kind === "text" && node.dataset.markdown !== "false") {
      const html = renderMarkdown(raw)
      if (html !== null) {
        node.innerHTML = html
        return
      }
    }

    node.textContent = raw
  },

  msgId() {
    return this.el.dataset.msgId
  },

  node(kind) {
    return this.el.querySelector(`[data-agentix="${kind}"]`)
  },
}

// Renders a finalized message's raw markdown (carried in `data-md`) into the node, so the
// reload/reconnect view matches what streamed. Falls back to the server-rendered raw text
// when no renderer is configured. `updated()` keeps it correct if the node is ever patched.
export const AgentixMarkdown = {
  mounted() {
    this.paint()
  },

  updated() {
    this.paint()
  },

  paint() {
    const raw = this.el.dataset.md
    if (raw == null) return
    const html = renderMarkdown(raw)
    if (html !== null) this.el.innerHTML = html
  },
}

// Composer hook: auto-grows the textarea, submits on Enter (Shift+Enter = newline),
// and clears the field after the form submits.
export const AgentixComposer = {
  mounted() {
    this.resize()
    this.el.addEventListener("input", () => this.resize())
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        if (this.el.value.trim()) this.el.form?.requestSubmit()
      }
    })
    this.el.form?.addEventListener("submit", () => {
      requestAnimationFrame(() => {
        this.el.value = ""
        this.resize()
      })
    })
  },

  resize() {
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 160) + "px"
  },
}

export default AgentixStream
