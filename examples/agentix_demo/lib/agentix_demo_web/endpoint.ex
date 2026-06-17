defmodule AgentixDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agentix_demo

  @session_options [
    store: :cookie,
    key: "_agentix_demo_key",
    signing_salt: "agentixdemo-session-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve the esbuild bundle (app.js) from priv/static/assets.
  plug(Plug.Static, at: "/assets", from: {:agentix_demo, "priv/static/assets"}, gzip: false)
  plug(Plug.Session, @session_options)
  plug(AgentixDemoWeb.Router)
end
