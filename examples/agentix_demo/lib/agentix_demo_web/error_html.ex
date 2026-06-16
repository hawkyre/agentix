defmodule AgentixDemoWeb.ErrorHTML do
  @moduledoc false
  use Phoenix.Component

  # Render plain status messages ("Not Found", "Internal Server Error") — no error pages
  # needed for this demo.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
