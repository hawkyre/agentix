// Agentix streaming hook.
//
// Renders the in-progress assistant message incrementally on the client so the
// server never re-diffs a growing string. Both the response text and the model's
// thinking stream this way. Attach it to the element that wraps the streaming
// message, give that element `phx-update="ignore"` (its content is client-owned)
// and a `data-msg-id` matching the streaming message id, and give it two child
// nodes the hook writes into — one per kind:
//
//   <div
//     :if={@streaming_message}
//     id={"agentix-stream-#{@streaming_message.id}"}
//     phx-hook="AgentixStream"
//     phx-update="ignore"
//     data-msg-id={@streaming_message.id}
//   >
//     <div data-agentix="thinking"></div>
//     <div data-agentix="text"></div>
//   </div>
//
// Register it with your LiveSocket:
//
//   import { AgentixStream } from "./agentix_stream_hook"
//   const liveSocket = new LiveSocket("/live", Socket, { hooks: { AgentixStream } })
//
// The server pushes two events, each tagged with `kind` ("text" | "thinking"):
//   * "agentix:seed"  — %{id, kind, text, seq} : the content + delta count so far,
//                       on a mid-stream (re)connect
//   * "agentix:delta" — %{id, kind, chunk, seq}: each streamed token
// Both are filtered by id so only the matching streaming element reacts. `seq` is a
// per-message counter shared across kinds; the hook drops any delta whose seq is below
// what it has already applied, so a reconnect during an active stream never
// double-renders leading tokens.
export const AgentixStream = {
  mounted() {
    // Next-accepted seq per kind; a delta below it is a duplicate already rendered.
    this.seq = { text: 0, thinking: 0 }

    this.handleEvent("agentix:seed", ({ id, kind, text, seq }) => {
      if (id !== this.msgId()) return
      const node = this.node(kind)
      if (!node) return
      node.textContent = text || ""
      if (text) node.hidden = false
      this.seq[kind] = seq || 0
    })

    this.handleEvent("agentix:delta", ({ id, kind, chunk, seq }) => {
      if (id !== this.msgId() || seq < this.seq[kind]) return
      const node = this.node(kind)
      if (!node) return
      node.hidden = false
      node.textContent += chunk
      this.seq[kind] = seq + 1
    })
  },

  msgId() {
    return this.el.dataset.msgId
  },

  node(kind) {
    return this.el.querySelector(`[data-agentix="${kind}"]`)
  },
}

// Composer hook: auto-grows the textarea, submits on Enter (Shift+Enter = newline),
// and clears the field after the form submits. Attach to the <textarea> inside the
// composer form (the <.composer> component already wires `phx-hook="AgentixComposer"`).
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
