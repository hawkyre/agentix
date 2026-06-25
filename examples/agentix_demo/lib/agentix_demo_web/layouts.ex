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
          // Agentix components use class-based dark mode (`.dark` on <html>), not the CDN's
          // `media` default. The Theme JS hook toggles the class; this restores it from
          // localStorage before paint so a dark-mode reload doesn't flash light.
          tailwind.config = {darkMode: "class"}
          if (localStorage.getItem("agentix-theme") === "dark") {
            document.documentElement.classList.add("dark")
          }
        </script>
        <script defer src="/assets/app.js">
        </script>
        {Phoenix.HTML.raw("<style>" <> AgentixDemoWeb.AgentixComponents.css() <> "</style>")}
      </head>
      <body class="bg-neutral-50 text-neutral-900 antialiased dark:bg-neutral-950 dark:text-neutral-100">
        {@inner_content}
      </body>
    </html>
    """
  end
end
