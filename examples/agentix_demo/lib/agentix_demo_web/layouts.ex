defmodule AgentixDemoWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  # Root layout. Inlines the Agentix component CSS (turn grouping + reasoning chevron) and
  # the streaming/composer JS hooks shipped with the library.
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Agentix Demo</title>
        <script src="https://cdn.tailwindcss.com">
        </script>
        <script type="importmap">
          {"imports": {
            "phoenix": "/assets/phoenix.mjs",
            "phoenix_live_view": "/assets/phoenix_live_view.esm.js"
          }}
        </script>
        <script type="module">
          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"
          import {AgentixStream, AgentixComposer} from "/assets/agentix_stream_hook.js"
          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrf}, hooks: {AgentixStream, AgentixComposer}})
          liveSocket.connect()
        </script>
        {Phoenix.HTML.raw("<style>" <> AgentixDemoWeb.AgentixComponents.css() <> "</style>")}
      </head>
      <body class="bg-neutral-50 text-neutral-900 antialiased">
        <main class="mx-auto max-w-3xl px-5">
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end
end
