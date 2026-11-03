defmodule FluxClawWeb.ChatLiveTest do
  use FluxClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @moduletag :live_view_smoke

  test "renders the dsh-style three-pane frame", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#sidebar-root")
    assert has_element?(view, "#sidebar-right")
  end

  test "right sidebar defaults to the plugin manager tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#plugin-panel")
    assert has_element?(view, "button[phx-value-tab=timeline]")
    assert has_element?(view, "button[phx-value-tab=memory]")
    assert has_element?(view, "button[phx-value-tab=plugins]")
  end

  test "switching right tabs shows memory and timeline panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> element("button[phx-value-tab=memory]") |> render_click() =~
             "记忆与技能"

    assert has_element?(view, "button[phx-value-tab=timeline]")

    assert view |> element("button[phx-value-tab=timeline]") |> render_click() =~
             "运行轨迹"

    # Switching back to plugins keeps the panel available.
    assert view |> element("button[phx-value-tab=plugins]") |> render_click() =~
             "Cordis 运行时"
  end
end
