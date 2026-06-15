if Code.ensure_loaded?(Phoenix.Endpoint) do
  defmodule Agentix.Test.Endpoint do
    @moduledoc false
    # Minimal endpoint so `Phoenix.LiveViewTest` can mount the chat fixture. Not shipped.
    use Phoenix.Endpoint, otp_app: :agentix

    socket("/live", Phoenix.LiveView.Socket)
  end
end
