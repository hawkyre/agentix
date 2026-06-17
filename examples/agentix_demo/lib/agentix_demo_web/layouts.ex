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
        <script>
          // The Agentix components are built for class-based dark mode. Without this the CDN
          // defaults to `media` (OS) dark mode, so the components' `dark:` styles would fire
          // on a dark-OS machine while the page stays light. No `.dark` class is ever set, so
          // the demo renders consistently light. (Add a toggle that flips `.dark` for dark mode.)
          tailwind.config = {darkMode: "class"}
        </script>
        <script defer src="/assets/app.js">
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
