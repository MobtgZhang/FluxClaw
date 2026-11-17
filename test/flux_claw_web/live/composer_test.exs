defmodule FluxClawWeb.ComposerTest do
  use FluxClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias FluxClaw.Agents

  setup do
    old = Application.get_env(:flux_claw, :llm)
    Application.put_env(:flux_claw, :llm, Keyword.put(old, :api_key, ""))
    Application.put_env(:flux_claw, :llm_capture_owner, self())

    on_exit(fn ->
      Application.put_env(:flux_claw, :llm, old)
      Application.delete_env(:flux_claw, :llm_capture_owner)
    end)

    :ok
  end

  test "attachments can upload before a session and be removed without starting work", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "budget.csv", content: String.duplicate("x", 100), type: "text/csv"}
      ])

    render_upload(upload, "budget.csv", 50)
    assert has_element?(view, "#composer-attachments article progress")
    render_upload(upload, "budget.csv", 50)
    assert has_element?(view, "#composer-attachments article strong", "budget.csv")
    refute has_element?(view, "#composer-attachments article progress")
    view |> element("#composer-attachments button") |> render_click()
    refute has_element?(view, "#composer-attachments")
    refute has_element?(view, "#chat-stop-btn")
    assert has_element?(view, "#workbench-welcome")
  end

  test "first send saves attachments and passes their paths and selected model to agent", %{
    conn: conn
  } do
    Application.put_env(:flux_claw, :llm,
      llm_module: FluxClaw.Test.CapturingLLM,
      model: "initial"
    )

    {:ok, view, _} = live(conn, "/")
    view |> element("#composer-model") |> render_click()
    view |> form("#composer-model-search", %{"query" => "reasoning-model"}) |> render_change()
    view |> element("#use-custom-model") |> render_click()
    view |> element("#reasoning-high") |> render_click()

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "budget.csv", content: "cost\n120", type: "text/csv"}
      ])

    render_upload(upload, "budget.csv")
    view |> form("#chat-send-form", %{"text" => "汇总预算"}) |> render_submit()
    path = assert_patch(view)
    session = Agents.get_session!(String.replace_prefix(path, "/chat/", ""))
    on_exit(fn -> File.rm_rf!(FluxClaw.Artifacts.root(session.id)) end)
    assert session.model == "reasoning-model"
    assert session.reasoning_effort == "high"
    assert_receive {:model_request, messages, opts}, 2_000
    assert opts == [model: "reasoning-model", reasoning_effort: "high"]
    message = Enum.find(Agents.list_messages(session.id), &(&1.role == "user"))
    assert message.content == "汇总预算"
    assert [%{"name" => "budget.csv", "path" => relative}] = message.metadata["attachments"]
    assert File.read!(Path.join(FluxClaw.Artifacts.root(session.id), relative)) == "cost\n120"
    assert List.last(messages)["content"] =~ relative
    assert has_element?(view, ".cw-sent-file", "budget.csv")
    refute has_element?(view, "#composer-attachments")
  end

  test "file-only send works and conversation navigation clears pending uploads", %{conn: conn} do
    {:ok, first} = Agents.create_session(%{title: "first"})
    {:ok, second} = Agents.create_session(%{title: "second"})
    {:ok, view, _} = live(conn, "/chat/#{first.id}")

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "notes.txt", content: "notes", type: "text/plain"}
      ])

    render_upload(upload, "notes.txt")
    render_patch(view, "/chat/#{second.id}")
    refute has_element?(view, "#composer-attachments")

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "notes.txt", content: "notes", type: "text/plain"}
      ])

    render_upload(upload, "notes.txt")
    view |> form("#chat-send-form", %{"text" => ""}) |> render_submit()
    assert has_element?(view, ".cw-sent-file", "notes.txt")
    assert Enum.any?(Agents.list_messages(second.id), &(&1.content == "请分析这些附件。"))
    on_exit(fn -> File.rm_rf!(FluxClaw.Artifacts.root(second.id)) end)
  end

  test "model and effort persist per conversation and unsupported effort resets", %{conn: conn} do
    {:ok, first} = Agents.create_session(%{title: "first"})
    {:ok, second} = Agents.create_session(%{title: "second", model: "other-model"})
    {:ok, view, _} = live(conn, "/chat/#{first.id}")
    view |> element("#composer-model") |> render_click()
    render_async(view)
    view |> form("#composer-model-search", %{"query" => "o3"}) |> render_change()
    view |> element("#use-custom-model") |> render_click()
    view |> element("#reasoning-high") |> render_click()
    assert Agents.get_session!(first.id).reasoning_effort == "high"
    render_patch(view, "/chat/#{second.id}")
    assert has_element?(view, "#composer-model .cw-selected-model", "other-model")
    render_patch(view, "/chat/#{first.id}")
    assert has_element?(view, "#composer-model .cw-effort-badge", "深入")
    view |> element("#composer-model") |> render_click()
    view |> form("#composer-model-search", %{"query" => "gpt-4.1"}) |> render_change()
    view |> element("#use-custom-model") |> render_click()
    assert Agents.get_session!(first.id).reasoning_effort == "auto"
    assert has_element?(view, "#reasoning-high[disabled]")
    assert Agents.get_session!(second.id).model == "other-model"
  end

  test "oversized attachments show actionable errors and block sending", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "large.txt", content: String.duplicate("x", 8_000_001), type: "text/plain"}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(upload, "large.txt")
    assert has_element?(view, "#composer-attachments .cw-upload-error", "8 MB")
    view |> form("#chat-send-form", %{"text" => "start"}) |> render_submit()
    assert has_element?(view, "#workbench-welcome")
    assert has_element?(view, "#composer-attachments")
  end

  test "failed first attachment save keeps uploads and retry opens the created conversation", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")

    upload =
      file_input(view, "#chat-send-form", :attachments, [
        %{name: "retry.txt", content: "retry", type: "text/plain"}
      ])

    render_upload(upload, "retry.txt")
    old_agents = Application.fetch_env!(:flux_claw, :agents)
    blocked_root = Path.join(System.tmp_dir!(), "composer-blocked-#{Ecto.UUID.generate()}")
    File.write!(blocked_root, "not a directory")
    Application.put_env(:flux_claw, :agents, Keyword.put(old_agents, :sandbox_root, blocked_root))

    on_exit(fn ->
      Application.put_env(:flux_claw, :agents, old_agents)
      File.rm(blocked_root)
    end)

    view |> form("#chat-send-form", %{"text" => "retry this"}) |> render_submit()
    assert has_element?(view, "#composer-attachments article strong", "retry.txt")
    assert has_element?(view, "#flash-error", "附件保存失败")
    Application.put_env(:flux_claw, :agents, old_agents)
    view |> form("#chat-send-form", %{"text" => "retry this"}) |> render_submit()
    path = assert_patch(view)
    sid = String.replace_prefix(path, "/chat/", "")
    assert [%{role: "user", metadata: %{"attachments" => [_]}} | _] = Agents.list_messages(sid)
    assert has_element?(view, ".cw-sent-file", "retry.txt")
    on_exit(fn -> File.rm_rf!(FluxClaw.Artifacts.root(sid)) end)
  end

  test "a running worker reloads the conversation model for the next message" do
    Application.put_env(:flux_claw, :llm,
      llm_module: FluxClaw.Test.CapturingLLM,
      model: "default"
    )

    {:ok, session} = Agents.create_session(%{model: "o3", reasoning_effort: "low"})
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, "agent:" <> session.id)
    pid = start_supervised!({FluxClaw.Agents.AgentWorker, session_id: session.id})
    GenServer.cast(pid, {:user_message, "first"})
    assert_receive {:model_request, _, [model: "o3", reasoning_effort: "low"]}, 2_000
    assert_receive {:assistant_done, "done", _}, 2_000
    {:ok, _} = Agents.update_session(session, %{model: "gpt-4.1", reasoning_effort: "auto"})
    GenServer.cast(pid, {:user_message, "second"})
    assert_receive {:model_request, _, [model: "gpt-4.1"]}, 2_000
    assert_receive {:assistant_done, "done", _}, 2_000
  end

  test "planning selection persists, reaches the worker, and can hand off without auto sending",
       %{conn: conn} do
    Application.put_env(:flux_claw, :llm, llm_module: FluxClaw.Test.CapturingLLM, model: "mock")
    {:ok, session} = Agents.create_session(%{title: "planning"})
    sid = session.id
    path = "/chat/#{sid}"
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, "agent:" <> sid)
    {:ok, view, _} = live(conn, path)
    view |> element("#execution-mode") |> render_change(%{"mode" => "plan"})
    assert has_element?(view, "#execution-mode-hint", "不修改文件")
    view |> form("#chat-send-form", %{"text" => "制定研究计划"}) |> render_submit()
    assert Agents.get_session!(sid).execution_mode == "plan"
    assert_receive {:model_request, messages, _}, 2_000
    assert hd(messages)["content"] =~ "当前为规划模式"
    assert_receive {:model_tools, tools}, 2_000
    refute Enum.any?(tools, &(&1.function.name == "shell_execute"))
    assert_receive {:assistant_done, "done", _}, 2_000
    render_patch(view, "/")
    render_patch(view, path)
    assert has_element?(view, "#execution-mode option[value=plan][selected]")
    send(view.pid, {:tool_start, "plan", "task_plan", %{}})
    send(view.pid, {:tool_done, "plan", "task_plan", "研究计划\n1. 核实资料\n2. 输出结论"})
    send(view.pid, {:assistant_done, "规划已整理", nil})
    view |> element("#details-toggle") |> render_click()
    before = length(Agents.list_messages(sid))
    view |> element("#plan-to-execution") |> render_click()
    assert_push_event(view, "composer-fill", %{text: "请按照上面的任务计划开始执行，并验证最终结果。"})
    assert Agents.get_session!(sid).execution_mode == "agent"
    assert length(Agents.list_messages(sid)) == before
    refute has_element?(view, "#plan-to-execution")
  end

  test "changing execution mode is blocked while a model request is running", %{conn: conn} do
    owner = self()

    Application.put_env(:flux_claw, :llm_mock_reply, fn _ ->
      send(owner, {:blocked_request, self()})

      receive do
        :finish -> %{content: "done", tool_calls: []}
      end
    end)

    on_exit(fn -> Application.delete_env(:flux_claw, :llm_mock_reply) end)
    {:ok, session} = Agents.create_session(%{title: "busy"})
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, "agent:" <> session.id)
    {:ok, view, _} = live(conn, "/chat/#{session.id}")
    view |> form("#chat-send-form", %{"text" => "work"}) |> render_submit()
    assert_receive {:blocked_request, request}, 2_000
    assert has_element?(view, "#execution-mode[disabled]")
    render_click(view, "execution_mode", %{"mode" => "plan"})
    assert Agents.get_session!(session.id).execution_mode == "agent"
    send(request, :finish)
    assert_receive {:assistant_done, "done", _}, 2_000
  end
end
