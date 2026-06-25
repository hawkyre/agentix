defmodule AgentixDemoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {AgentixDemoWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AgentixDemoWeb do
    pipe_through(:browser)

    # `/` mints a fresh conversation id and redirects to `/c/:id` so a page reload keeps the
    # same conversation (its history is reloaded from Postgres on mount).
    live("/", ChatLive, :new)
    live("/c/:id", ChatLive, :show)
  end
end
