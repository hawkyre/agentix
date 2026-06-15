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
//   * "agentix:seed"  — %{id, text}  : the partial text on a mid-stream (re)connect
//   * "agentix:delta" — %{id, chunk} : each streamed token
// Both are filtered by id so only the matching streaming element reacts.
export const AgentixStream = {
  mounted() {
    this.handleEvent("agentix:seed", ({ id, text }) => {
      if (id === this.msgId()) this.el.textContent = text || ""
    })

    this.handleEvent("agentix:delta", ({ id, chunk }) => {
      if (id === this.msgId()) this.el.textContent += chunk
    })
  },

  msgId() {
    return this.el.dataset.msgId
  },
}

export default AgentixStream
