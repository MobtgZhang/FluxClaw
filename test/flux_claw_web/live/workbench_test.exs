defmodule FluxClawWeb.WorkbenchTest do
  use FluxClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "project cards survive leaving and reentering the directory", %{conn: conn} do
    {:ok, project} = FluxClaw.Projects.create_project(%{title: "年度规划"})
    {:ok, view, _} = live(conn, "/projects")
    selector = "#workspace_projects-#{project.id}"
    assert has_element?(view, selector)
    view |> element("#nav-skills") |> render_click()
    assert_patch(view, "/skills")
    assert has_element?(view, "#skills-page")
    view |> element("#nav-projects") |> render_click()
    assert_patch(view, "/projects")
    assert has_element?(view, selector)
    view |> element("#{selector} a") |> render_click()
    assert_patch(view, "/p/#{project.id}")
    assert has_element?(view, "#workbench-welcome")
  end

  test "office scenes filter and create a draft without starting an agent", %{conn: conn} do
    {:ok, view, _} = live(conn, "/skills")
    assert has_element?(view, "#template-build")
    view |> element("#skill-filter-分析") |> render_click()
    assert has_element?(view, "#template-data")
    refute has_element?(view, "#template-build")
    view |> element("#template-data") |> render_click()
    assert_patch(view)
    assert_push_event(view, "composer-fill", %{text: text})
    assert text =~ "CSV"
    assert has_element?(view, "#workbench-welcome")
    refute has_element?(view, "#skills-page")
    refute has_element?(view, "#chat-stop-btn")
  end

  test "command palette searches real projects and handles empty results", %{conn: conn} do
    {:ok, project} = FluxClaw.Projects.create_project(%{title: "季度预算"})
    {:ok, view, _} = live(conn, "/")
    view |> element("#command-trigger") |> render_click()
    view |> form("#command-search-form", %{"query" => "季度预算"}) |> render_change()
    assert has_element?(view, "#command-results a[href='/p/#{project.id}']")
    refute has_element?(view, "#command-new_chat")
    view |> form("#command-search-form", %{"query" => "no-such-work-94571"}) |> render_change()
    assert has_element?(view, "#command-empty")
    render_click(view, "close_drawers")
    refute has_element?(view, "#command-palette")
  end

  test "settings tabs keep one complete form and do not expose stored credentials", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#sidebar-settings") |> render_click()
    assert has_element?(view, "#settings-center[role=dialog]")
    assert has_element?(view, "#settings-api-key[type=password][value='']")
    view |> form("#settings-form", %{"model" => "draft-model"}) |> render_change()
    view |> element("#settings-tab-tools") |> render_click()
    assert has_element?(view, "#settings-model-section[hidden]")
    assert has_element?(view, "#settings-tools-section:not([hidden])")
    assert has_element?(view, "#settings-form #settings-model-text[value=draft-model]")
    view |> element("#settings-tab-integrations") |> render_click()
    assert has_element?(view, "#settings-integrations-section #integration-settings")
    assert has_element?(view, "#settings-integrations-section #plugin-panel")
    refute has_element?(view, "#settings-form #integration-settings")
    view |> element("#settings-tab-tools") |> render_click()
    assert has_element?(view, "#settings-form #settings-model-text[value=draft-model]")
    view |> element("#settings-tab-appearance") |> render_click()
    assert has_element?(view, "#settings-appearance-section:not([hidden])")
    view |> element("#close-settings") |> render_click()
    refute has_element?(view, "#settings-center")
  end

  test "task details show actual plans and paired tool calls with two focused tabs", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    send(view.pid, {:tool_start, "plan-1", "task_plan", %{}})
    send(view.pid, {:tool_done, "plan-1", "task_plan", "研究计划\n1. 核实资料\n2. 整理报告"})
    view |> element("#details-toggle") |> render_click()
    assert has_element?(view, "#current-task-plan .cw-plan-step", "核实资料")
    assert has_element?(view, "#current-task-plan .cw-plan-step", "整理报告")
    assert has_element?(view, "#task-plan-panel .cw-tool-count", "1 次调用")
    assert has_element?(view, "#task-activity details:only-child")
    refute has_element?(view, "#task-plan-empty")
    view |> element("#detail-tab-files") |> render_click()
    assert has_element?(view, "#artifact-panel")
    view |> element("#close-task-details") |> render_click()
    assert has_element?(view, "#details-toggle[aria-expanded=false]")
  end

  test "project switcher filters projects and updates real task context", %{conn: conn} do
    {:ok, project} = FluxClaw.Projects.create_project(%{title: "团队资料库"})
    {:ok, view, _} = live(conn, "/")
    view |> element("#project-switcher") |> render_click()
    view |> form("#project-search-form", %{"query" => "不匹配的项目"}) |> render_change()
    assert has_element?(view, "#switcher-projects #switcher-empty")
    view |> form("#project-search-form", %{"query" => "团队资料库"}) |> render_change()
    assert has_element?(view, "#switcher-projects a")
    refute has_element?(view, "#switcher-projects a:nth-of-type(2)")
    view |> element("#project_choices-#{project.id}") |> render_click()
    assert_patch(view, "/p/#{project.id}")
    assert has_element?(view, "#project-switcher", "团队资料库")
    refute has_element?(view, "#project-switcher-panel")
    view |> element("#project-switcher") |> render_click()
    assert has_element?(view, "#project_choices-#{project.id}[aria-current=true]")
    render_click(view, "close_drawers")
    refute has_element?(view, "#project-switcher-panel")
  end

  test "new task is a draft and repeated clicks do not create empty conversations", %{conn: conn} do
    {:ok, project} = FluxClaw.Projects.create_project(%{title: "drafts"})
    {:ok, view, _} = live(conn, "/p/#{project.id}")
    view |> element("#new-task") |> render_click()
    assert_patch(view, "/p/#{project.id}")
    view |> element("#new-task") |> render_click()
    assert_patch(view, "/p/#{project.id}")
    assert FluxClaw.Agents.list_sessions_for_project(project.id) == []
    assert has_element?(view, "#workbench-welcome")
    refute has_element?(view, "#mode-build")
    refute has_element?(view, "#topbar-model")
    refute has_element?(view, "#detail-tab-memory")
    view |> element("#sidebar-collapse") |> render_click()
    view |> element("#rail-projects") |> render_click()
    assert_patch(view, "/projects")
    assert has_element?(view, "#projects-page")
  end

  test "task files survive tab changes and do not leak to another session", %{conn: conn} do
    {:ok, first} = FluxClaw.Agents.create_session(%{title: "files"})
    {:ok, second} = FluxClaw.Agents.create_session(%{title: "empty"})
    root = FluxClaw.Artifacts.root(first.id)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "report.md"), "report")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, view, _} = live(conn, "/chat/#{first.id}")
    view |> element("#details-toggle") |> render_click()
    view |> element("#detail-tab-files") |> render_click()
    assert has_element?(view, "#artifact-files article", "report.md")
    view |> element("#detail-tab-timeline") |> render_click()
    view |> element("#detail-tab-files") |> render_click()
    assert has_element?(view, "#artifact-files article a[download]")
    render_patch(view, "/chat/#{second.id}")
    refute has_element?(view, "#artifact-files article")
    assert has_element?(view, "#artifact-files #artifacts-empty")
  end
end
