defmodule AgentixDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agentix_demo

  @session_options [
    store: :cookie,
    key: "_agentix_demo_key",
    signing_salt: "agentixdemo-session-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(AgentixDemoWeb.Assets)
  plug(Plug.Session, @session_options)
  plug(AgentixDemoWeb.Router)
end
