defmodule AgentixDemoWeb.Assets do
  @moduledoc false
  # Serves the three ESM files the browser needs straight from their dep priv dirs, so the
  # demo runs with no build step. (A real app would bundle these with esbuild.)
  import Plug.Conn

  @files %{
    "phoenix.mjs" => {:phoenix, "priv/static/phoenix.mjs"},
    "phoenix_live_view.esm.js" => {:phoenix_live_view, "priv/static/phoenix_live_view.esm.js"},
    "agentix_stream_hook.js" => {:agentix, "priv/static/agentix_stream_hook.js"}
  }

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["assets", file]} = conn, _opts) do
    case Map.fetch(@files, file) do
      {:ok, {app, rel}} ->
        conn
        |> put_resp_content_type("text/javascript")
        |> send_file(200, Application.app_dir(app, rel))
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
