defmodule AgentixDemoWeb.GalleryLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint AgentixDemoWeb.Endpoint

  test "the /gallery storybook renders every component state" do
    conn = Plug.Test.init_test_session(build_conn(), %{})
    {:ok, _live, html} = live(conn, "/gallery")

    assert html =~ "Component states"
    # reasoning panel (the previously-unused .reasoning/1 is wired here)
    assert html =~ "Thought for 4s"
    # tool rows incl. the result inspector
    assert html =~ "get_weather"
    assert html =~ "sunny in Tokyo"
    assert html =~ "<details"
    # pending controls
    assert html =~ "Permission required"
    assert html =~ ~s(phx-submit="resolve")
    # banners + composer
    assert html =~ "reach the model"
    assert html =~ ~s(phx-submit="send")
  end
end
