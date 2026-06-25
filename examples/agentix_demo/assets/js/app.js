import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { marked } from "../vendor/marked.esm.js"
import DOMPurify from "../vendor/purify.es.mjs"
import {
  AgentixStream,
  AgentixComposer,
  AgentixMarkdown,
  AgentixAutoScroll,
  configureMarkdown,
  // In-repo demo: Agentix is a `path:` dep, so its hook lives at the repo root. An external
  // host (agentix as a hex/git dep) would import from "../../deps/agentix/priv/static/…".
} from "../../../../priv/static/agentix_stream_hook.js"

// Agentix renders message text as markdown by default, but ships no markdown engine — the
// host wires one. Model output is untrusted, so DOMPurify sanitizes the HTML marked produces.
configureMarkdown((raw) => DOMPurify.sanitize(marked.parse(raw)))

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Server-side theme toggle: ChatLive fires `toggle_theme` and pushes `set-theme` back here.
// On connect we report the persisted choice so the server's toggle state matches the page.
const Theme = {
  mounted() {
    const saved = localStorage.getItem("agentix-theme") === "dark" ? "dark" : "light"
    this.apply(saved)
    this.pushEvent("theme-restored", { theme: saved })
    this.handleEvent("set-theme", ({ theme }) => this.apply(theme))
  },
  apply(theme) {
    document.documentElement.classList.toggle("dark", theme === "dark")
    localStorage.setItem("agentix-theme", theme)
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { AgentixStream, AgentixComposer, AgentixMarkdown, AgentixAutoScroll, Theme },
})

liveSocket.connect()
window.liveSocket = liveSocket
