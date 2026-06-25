defmodule AgentixDemoWeb.Shell do
  @moduledoc false
  # The app chrome shared by every LiveView: sticky header (branding + nav), a server-side
  # theme toggle (`phx-click="toggle_theme"`, handled by the host LiveView), and a content
  # slot. `data-theme` on the root mirrors the `:theme` assign so the toggle is observable in
  # `Phoenix.LiveViewTest`; the actual `.dark` class flip + persistence is the `Theme` JS hook.
  use Phoenix.Component

  attr :theme, :string, default: "light"
  attr :active, :atom, default: :chat
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div data-theme={@theme} class="flex min-h-screen flex-col">
      <header class="sticky top-0 z-30 border-b border-neutral-200/80 bg-neutral-50/85 backdrop-blur dark:border-neutral-800/80 dark:bg-neutral-950/85">
        <div class="mx-auto flex h-14 w-full max-w-3xl items-center gap-3 px-5">
          <div class="grid h-7 w-7 place-items-center rounded-md bg-neutral-900 text-[13px] font-semibold text-neutral-50 dark:bg-neutral-100 dark:text-neutral-900">
            A
          </div>
          <div class="leading-tight">
            <div class="text-[13px] font-semibold tracking-tight">Agentix Demo</div>
            <div class="text-[11px] text-neutral-500 dark:text-neutral-400">
              LiveView-native agent runtime
            </div>
          </div>
          <nav class="ml-4 hidden items-center gap-1 rounded-lg bg-neutral-200/60 p-0.5 dark:bg-neutral-800/60 sm:flex">
            <.nav_link href="/" label="Chat" active={@active == :chat} />
            <.nav_link href="/gallery" label="Components" active={@active == :gallery} />
          </nav>
          <button
            id="theme-toggle"
            phx-hook="Theme"
            phx-click="toggle_theme"
            data-theme={@theme}
            title="Toggle theme"
            aria-label="Toggle theme"
            class="ml-auto grid h-9 w-9 place-items-center rounded-md border border-neutral-200 text-neutral-600 transition hover:bg-neutral-100 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
          >
            <svg
              class="h-[18px] w-[18px] dark:hidden"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="12" cy="12" r="4" />
              <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
            </svg>
            <svg
              class="hidden h-[18px] w-[18px] dark:block"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
            </svg>
          </button>
        </div>
      </header>

      <main class="mx-auto flex w-full max-w-3xl flex-1 flex-col px-5">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "rounded-md px-3 py-1.5 text-[13px] font-medium transition",
        @active && "bg-neutral-50 text-neutral-900 shadow-sm dark:bg-neutral-950 dark:text-neutral-100",
        !@active && "text-neutral-600 hover:text-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-100"
      ]}
    >
      {@label}
    </a>
    """
  end
end
