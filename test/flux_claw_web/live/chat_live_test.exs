defmodule FluxClawWeb.ChatLiveTest do
  use FluxClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "welcome has one composer and collapsed details", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#workbench-welcome")
    assert has_element?(view, "#chat-send-form textarea[phx-hook=ChatComposer]")
    assert has_element?(view, "#details-toggle[aria-expanded=false]")
    assert has_element?(view, "#conversation-turns[phx-update=stream]")
    assert has_element?(view, "#new-task")
  end

  test "examples populate the draft without starting a task", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#example-research") |> render_click()
    assert_push_event(view, "composer-fill", %{text: text})
    assert text =~ "搜索"
    assert has_element?(view, "#workbench-welcome")
  end

  test "details exposes task progress and files, integrations live in settings", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#details-toggle") |> render_click()
    assert has_element?(view, "#details-toggle[aria-expanded=true]")
    assert has_element?(view, "#task-plan-panel:not([hidden])")
    refute has_element?(view, "#detail-tab-plugins")
    view |> element("#detail-tab-files") |> render_click()
    assert has_element?(view, "#artifact-panel:not([hidden])")
    view |> element("#refresh-artifacts") |> render_click()
    assert has_element?(view, "#artifact-files")
    render_click(view, "close_drawers")
    assert has_element?(view, "#details-toggle[aria-expanded=false]")
    view |> element("#sidebar-settings") |> render_click()
    view |> element("#settings-tab-integrations") |> render_click()
    assert has_element?(view, "#integration-settings")
    assert has_element?(view, "#native-integrations")
  end

  test "empty user answers keep the actionable question visible", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    send(view.pid, {:ask_user, 123, "What should I do?"})
    assert has_element?(view, "#ask-user-form")
    view |> form("#ask-user-form", %{"text" => " ", "ref" => "123"}) |> render_submit()
    assert has_element?(view, "#ask-user-form")
  end
end
