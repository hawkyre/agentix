import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { marked } from "../vendor/marked.esm.js"
import DOMPurify from "../vendor/purify.es.mjs"
import {
  AgentixStream,
  AgentixComposer,
  AgentixMarkdown,
  configureMarkdown,
  // In-repo demo: Agentix is a `path:` dep, so its hook lives at the repo root. An external
  // host (agentix as a hex/git dep) would import from "../../deps/agentix/priv/static/…".
} from "../../../../priv/static/agentix_stream_hook.js"

// Agentix renders message text as markdown by default, but ships no markdown engine — the
// host wires one. Model output is untrusted, so DOMPurify sanitizes the HTML marked produces.
configureMarkdown((raw) => DOMPurify.sanitize(marked.parse(raw)))

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { AgentixStream, AgentixComposer, AgentixMarkdown },
})

liveSocket.connect()
window.liveSocket = liveSocket
