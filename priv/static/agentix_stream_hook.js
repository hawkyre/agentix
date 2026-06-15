// Agentix streaming hook.
//
// Renders the in-progress assistant message incrementally on the client so the
// server never re-diffs a growing string. Attach it to the element that holds the
// streaming message and give that element `phx-update="ignore"` (its content is
// client-owned) and a `data-msg-id` matching the streaming message id:
//
//   <div
//     :if={@streaming_message}
//     id={"agentix-stream-#{@streaming_message.id}"}
//     phx-hook="AgentixStream"
//     phx-update="ignore"
//     data-msg-id={@streaming_message.id}
//   ></div>
//
// Register it with your LiveSocket:
//
//   import { AgentixStream } from "./agentix_stream_hook"
//   const liveSocket = new LiveSocket("/live", Socket, { hooks: { AgentixStream } })
//
// The server pushes two events:
//   * "agentix:seed"  — %{id, text, seq} : the partial text + delta count on a
//                       mid-stream (re)connect
//   * "agentix:delta" — %{id, chunk, seq}: each streamed token, tagged with its
//                       monotonic per-message sequence number
// Both are filtered by id so only the matching streaming element reacts. `seq` lets
// the hook drop a delta already covered by the seed (or any earlier replay), so a
// reconnect during an active stream never double-renders leading tokens.
export const AgentixStream = {
  mounted() {
    // Next delta seq we will accept; deltas below it are duplicates already rendered.
    this.seq = 0

    this.handleEvent("agentix:seed", ({ id, text, seq }) => {
      if (id !== this.msgId()) return
      this.el.textContent = text || ""
      this.seq = seq || 0
    })

    this.handleEvent("agentix:delta", ({ id, chunk, seq }) => {
      if (id !== this.msgId() || seq < this.seq) return
      this.el.textContent += chunk
      this.seq = seq + 1
    })
  },

  msgId() {
    return this.el.dataset.msgId
  },
}

export default AgentixStream
