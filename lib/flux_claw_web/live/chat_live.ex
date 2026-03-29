defmodule FluxClawWeb.ChatLive do
  use FluxClawWeb, :live_view

  require Logger

  alias FluxClaw.Agents
  alias FluxClaw.Agents.AgentWorker
  alias FluxClaw.Agents.Orchestrator
  alias FluxClaw.Memory
  alias FluxClaw.Projects
  alias FluxClaw.Projects.Project, as: Pj

  @impl true
  def mount(_params, _session, socket) do
    # LiveView 会调用 mount 两次：先静态 HTML（connected? false），WebSocket 连上后再调一次（connected? true）。
    # 第二次绝不能把 handle_params 已写入的 session / log 等重置，否则历史消息在页面上会「消失」、composer 状态错乱。
    socket =
      if socket.assigns[:chat_lv_mount_init] == true do
        wire_pubsub_after_static_render(socket)
      else
        initial_chat_assigns(socket)
      end

    {:ok, socket}
  end

  defp initial_chat_assigns(socket) do
    socket
    |> assign(:chat_lv_mount_init, true)
    |> assign(:page_title, "FluxClaw")
    |> assign(:projects, [])
    |> assign(:project, nil)
    |> assign(:sessions, [])
    |> assign(:session, nil)
    |> assign(:log, [])
    |> assign(:draft_assistant, nil)
    |> assign(:draft_reasoning, nil)
    |> assign(:pending_ask, nil)
    |> assign(:skill_proposal, nil)
    |> assign(:sidebar_open, false)
    |> assign(:settings_open, false)
    |> assign(:menu, nil)
    |> assign(:move_target, nil)
    |> assign(:editing, nil)
    |> assign(:checkpoints, [])
    |> assign(:skills_sidebar, [])
    |> assign(:chat_topic, nil)
    |> assign(:settings_form, settings_form_defaults())
    |> assign(:nav_open, %{
      "projects" => true,
      "chats" => true,
      "skills" => true,
      "memory" => true
    })
    |> assign(:skill_editor, nil)
    |> assign(:external_link_prompt, nil)
    |> assign(:context_menu, nil)
    |> assign(:menu_anchor, nil)
    |> assign(:skill_import_open, false)
    |> assign(:skill_import_files, [])
    |> assign(:memory_doc_files, [])
    |> assign(:settings_models, [])
    |> assign(:agent_busy, false)
    |> assign(:chat_subscribed_topic, nil)
  end

  defp wire_pubsub_after_static_render(socket) do
    if connected?(socket) && match?(%{id: _}, socket.assigns[:session]) do
      socket
      |> subscribe_session(socket.assigns.session.id)
      |> assign(:agent_busy, composer_agent_busy?(socket.assigns.session.id))
    else
      socket
    end
  end

  defp settings_form_defaults do
    fc = FluxClaw.ConfigLoader.load()
    llm = Application.get_env(:flux_claw, :llm, []) |> Map.new()
    paths = Application.get_env(:flux_claw, :cache_paths, []) |> Map.new()
    agents = Application.get_env(:flux_claw, :agents, []) |> Map.new()

    api_key =
      Map.get(fc, :openai_api_key) || llm[:api_key] || ""

    max =
      Map.get(fc, :agents_max_steps) || agents[:max_steps]

    max_str =
      cond do
        max == -1 -> "-1"
        is_integer(max) -> Integer.to_string(max)
        true -> "32"
      end

    self_evolve =
      case Map.get(fc, :agents_self_evolve) do
        nil -> Map.get(agents, :self_evolve, true)
        v -> v
      end

    crystallize_skills =
      case Map.get(fc, :agents_crystallize_skills) do
        nil -> Map.get(agents, :crystallize_skills, true)
        v -> v
      end

    crystallize_mode =
      Map.get(fc, :agents_crystallize_mode) || Map.get(agents, :crystallize_mode) || :auto

    temp =
      case Map.get(fc, :openai_temperature) || llm[:temperature] do
        f when is_float(f) -> :erlang.float_to_binary(f, decimals: 2)
        f when is_integer(f) -> Integer.to_string(f)
        _ -> ""
      end

    top_p =
      case Map.get(fc, :openai_top_p) || llm[:top_p] do
        f when is_float(f) -> :erlang.float_to_binary(f, decimals: 2)
        f when is_integer(f) -> Integer.to_string(f)
        _ -> ""
      end

    top_k =
      case Map.get(fc, :openai_top_k) || llm[:top_k] do
        i when is_integer(i) -> Integer.to_string(i)
        _ -> ""
      end

    %{
      "base_url" => Map.get(fc, :openai_base_url) || llm[:base_url] || "",
      "model" => Map.get(fc, :openai_model) || llm[:model] || "",
      "api_key" => api_key,
      "max_steps" => max_str,
      "temperature" => temp,
      "top_p" => top_p,
      "top_k" => top_k,
      "cache_root" => Map.get(fc, :cache_root) || paths[:cache_root] || "",
      "external_skills" => Map.get(fc, :cache_external_skills) || paths[:external_skills] || "",
      "internal_skills" => Map.get(fc, :cache_internal_skills) || paths[:internal_skills] || "",
      "history_root" => Map.get(fc, :cache_history_root) || paths[:history_root] || "",
      "memory_root" => Map.get(fc, :cache_memory_root) || paths[:memory_root] || "",
      "self_evolve" => if(self_evolve, do: "true", else: "false"),
      "crystallize_skills" => if(crystallize_skills, do: "true", else: "false"),
      "crystallize_mode" => to_string(crystallize_mode)
    }
  end

  @impl true
  def handle_params(params, _uri, socket) do
    projects = Projects.list_projects()
    socket = assign(socket, :projects, projects)

    project_id = Map.get(params, "project_id")
    session_id = Map.get(params, "id")

    socket = assign(socket, :menu, nil)

    socket =
      case {session_id, project_id} do
        {sid, _} when is_binary(sid) ->
          load_session_view(socket, sid, projects)

        {nil, pid} when is_binary(pid) ->
          load_project_view(socket, pid, projects)

        {nil, nil} ->
          load_home_view(socket, projects)
      end

    {:noreply, socket}
  end

  defp load_home_view(socket, projects) do
    socket
    |> assign(:session, nil)
    |> assign(:log, [])
    |> assign(:draft_assistant, nil)
    |> assign(:draft_reasoning, nil)
    |> assign(:pending_ask, nil)
    |> assign(:checkpoints, [])
    |> assign(:skills_sidebar, [])
    |> assign(:chat_topic, nil)
    |> assign(:chat_subscribed_topic, nil)
    |> assign(:agent_busy, false)
    |> assign(:page_title, "FluxClaw")
    |> then(fn s ->
      case List.first(projects) do
        %Pj{} = p ->
          s
          |> assign(:project, p)
          |> assign(:sessions, Agents.list_sessions_for_project(p.id))
          |> assign(:skills_sidebar, Memory.list_skills_for_project(p.id))
          |> assign(:memory_doc_files, Memory.list_memory_markdown_docs())

        _ ->
          s
          |> assign(:project, nil)
          |> assign(:sessions, [])
          |> assign(:skills_sidebar, [])
          |> assign(:memory_doc_files, Memory.list_memory_markdown_docs())
      end
    end)
    |> maybe_unsubscribe(nil)
  end

  defp load_project_view(socket, project_id, _projects) do
    case Projects.get_project(project_id) do
      nil ->
        socket
        |> put_flash(:error, "项目不存在")
        |> push_navigate(to: ~p"/")

      project ->
        socket
        |> assign(:project, project)
        |> assign(:sessions, Agents.list_sessions_for_project(project.id))
        |> assign(:session, nil)
        |> assign(:log, [])
        |> assign(:draft_assistant, nil)
        |> assign(:draft_reasoning, nil)
        |> assign(:pending_ask, nil)
        |> assign(:checkpoints, [])
        |> assign(:skills_sidebar, Memory.list_skills_for_project(project.id))
        |> assign(:memory_doc_files, Memory.list_memory_markdown_docs())
        |> assign(:page_title, project.title)
        |> assign(:chat_topic, nil)
        |> assign(:chat_subscribed_topic, nil)
        |> assign(:agent_busy, false)
        |> maybe_unsubscribe(nil)
    end
  end

  defp load_session_view(socket, session_id, projects) do
    case Agents.get_session(session_id) do
      nil ->
        socket
        |> put_flash(:error, "会话不存在")
        |> push_navigate(to: ~p"/")

      session ->
        project =
          case session.project_id do
            pid when is_binary(pid) -> Projects.get_project(pid)
            _ -> nil
          end

        project = project || List.first(projects)

        log = history_entries(Agents.list_messages(session.id))
        checkpoints = Memory.list_checkpoints_for_session(session.id)

        skills =
          if project do
            Memory.list_skills_for_project(project.id)
          else
            Memory.list_skills_recent(24)
          end

        socket
        |> assign(:session, session)
        |> assign(:project, project)
        |> assign(
          :sessions,
          if(project, do: Agents.list_sessions_for_project(project.id), else: [])
        )
        |> assign(:log, log)
        |> assign(:draft_assistant, nil)
        |> assign(:draft_reasoning, nil)
        |> assign(:pending_ask, nil)
        |> assign(:checkpoints, checkpoints)
        |> assign(:skills_sidebar, skills)
        |> assign(:memory_doc_files, Memory.list_memory_markdown_docs())
        |> assign(:page_title, session.title)
        |> subscribe_session(session.id)
        |> assign(:agent_busy, composer_agent_busy?(session.id))
    end
  end

  defp maybe_unsubscribe(socket, new_topic) do
    old = socket.assigns.chat_topic

    socket =
      if old && old != new_topic && connected?(socket) do
        Phoenix.PubSub.unsubscribe(FluxClaw.PubSub, old)

        if socket.assigns[:chat_subscribed_topic] == old do
          assign(socket, :chat_subscribed_topic, nil)
        else
          socket
        end
      else
        socket
      end

    socket
  end

  defp subscribe_session(socket, session_id) do
    t = topic(session_id)
    socket = maybe_unsubscribe(socket, t)

    socket =
      if connected?(socket) do
        socket =
          if socket.assigns[:chat_subscribed_topic] != t do
            Phoenix.PubSub.subscribe(FluxClaw.PubSub, t)
            assign(socket, :chat_subscribed_topic, t)
          else
            socket
          end

        if AgentWorker.needs_resume?(session_id) do
          Orchestrator.ensure_worker(session_id)
        end

        socket
      else
        socket
      end

    assign(socket, :chat_topic, t)
  end

  defp topic(id), do: "agent:" <> id

  defp history_entries(messages) do
    Enum.flat_map(messages, fn m ->
      try do
        message_to_log_fragment(m)
      rescue
        _ ->
          Logger.warning("skip bad agent_message row: #{inspect(Map.take(m, [:id, :role]))}")
          []
      end
    end)
  end

  defp message_to_log_fragment(m) do
    case m.role do
      "reasoning" ->
        c = message_content_string(m.content)
        if c != "", do: [{:reasoning, c}], else: []

      "tool" ->
        case meta_phase(m.metadata) do
          "start" ->
            args = decode_tool_args(m.content)
            n = m.tool_name || "tool"
            [{:tool_start, n, args}]

          "done" ->
            id = meta_call_id(m.metadata)
            n = m.tool_name || "tool"
            [{:tool_done, id, n, message_content_string(m.content)}]

          _ ->
            []
        end

      "user" ->
        [{:history, "user", message_content_string(m.content)}]

      "assistant" ->
        tc = meta_tool_calls_list(m.metadata)
        c = message_content_string(m.content)

        cond do
          tc != [] and c != "" ->
            [{:history, "assistant", c}]

          tc != [] ->
            # 仅有 tool_calls、正文为空时仍占一条，避免历史里「用户下一条直接是工具」看起来像丢消息
            [{:history, "assistant", "（已发起工具调用）"}]

          true ->
            if c != "", do: [{:history, "assistant", c}], else: []
        end

      _ ->
        []
    end
  end

  defp message_content_string(nil), do: ""

  defp message_content_string(s) when is_binary(s), do: s

  defp message_content_string(other), do: inspect(other)

  defp meta_phase(nil), do: nil

  defp meta_phase(meta) when is_map(meta) do
    Map.get(meta, "phase") || Map.get(meta, :phase)
  end

  defp meta_phase(_), do: nil

  defp meta_call_id(nil), do: "call"

  defp meta_call_id(meta) when is_map(meta) do
    Map.get(meta, "call_id") || Map.get(meta, :call_id) || "call"
  end

  defp meta_call_id(_), do: "call"

  defp meta_tool_calls_list(nil), do: []

  defp meta_tool_calls_list(meta) when is_map(meta) do
    raw = Map.get(meta, "tool_calls") || Map.get(meta, :tool_calls)

    cond do
      is_list(raw) -> raw
      is_map(raw) and map_size(raw) > 0 -> [raw]
      true -> []
    end
  end

  defp meta_tool_calls_list(_), do: []

  defp decode_tool_args(nil), do: %{}

  defp decode_tool_args(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp decode_tool_args(_), do: %{}

  defp parse_px(nil), do: 0
  defp parse_px(n) when is_integer(n), do: n

  defp parse_px(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp parse_px(n) when is_float(n), do: round(n)

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open, &(!&1))}
  end

  def handle_event("toggle_settings", _params, socket) do
    open = !socket.assigns.settings_open

    socket =
      if open do
        assign(socket, :settings_form, settings_form_defaults())
      else
        socket
      end

    {:noreply, assign(socket, :settings_open, open)}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply,
     assign(socket,
       menu: nil,
       move_target: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  def handle_event("open_context_menu", params, socket) do
    t = params["type"]
    id = params["id"]

    anchor = %{
      top: parse_px(params["top"]),
      left: parse_px(params["left"]),
      right: parse_px(params["right"]),
      bottom: parse_px(params["bottom"])
    }

    {:noreply,
     assign(socket,
       context_menu: {t, id},
       menu_anchor: anchor,
       menu: nil,
       move_target: nil
     )}
  end

  def handle_event("toggle_nav", %{"section" => section}, socket) do
    nav = socket.assigns.nav_open

    if Map.has_key?(nav, section) do
      cur = Map.fetch!(nav, section)
      {:noreply, assign(socket, :nav_open, Map.put(nav, section, !cur))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_menu", %{"type" => type, "id" => id}, socket) do
    cur = socket.assigns.menu

    menu =
      if cur == {type, id} do
        nil
      else
        {type, id}
      end

    {:noreply, assign(socket, menu: menu, move_target: nil)}
  end

  def handle_event("open_move", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       move_target: {type, id},
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  def handle_event("new_project", %{"title" => title}, socket) do
    title = if title in [nil, ""], do: "新项目", else: title

    case Projects.create_project(%{title: title}) do
      {:ok, p} ->
        {:noreply,
         socket
         |> put_flash(:info, "已创建项目")
         |> push_patch(to: ~p"/p/#{p.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "创建失败")}
    end
  end

  def handle_event("new_project", _params, socket) do
    case Projects.create_project(%{title: "新项目"}) do
      {:ok, p} -> {:noreply, push_patch(socket, to: ~p"/p/#{p.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "创建失败")}
    end
  end

  def handle_event("new_chat", %{"title" => title}, socket) do
    title = if title in [nil, ""], do: "新对话", else: title

    pid =
      case socket.assigns.project do
        %{id: id} -> id
        _ -> Projects.ensure_default_project().id
      end

    case Agents.create_session(%{title: title, project_id: pid}) do
      {:ok, s} -> {:noreply, push_patch(socket, to: ~p"/chat/#{s.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "创建会话失败")}
    end
  end

  def handle_event("new_chat", _params, socket) do
    pid =
      case socket.assigns.project do
        %{id: id} -> id
        _ -> Projects.ensure_default_project().id
      end

    case Agents.create_session(%{project_id: pid}) do
      {:ok, s} -> {:noreply, push_patch(socket, to: ~p"/chat/#{s.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "创建会话失败")}
    end
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case Agents.get_session(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "会话不存在")}

      s ->
        stop_session_worker(s.id)
        Agents.delete_session(s)

        {:noreply,
         socket
         |> assign(:menu, nil)
         |> assign(:move_target, nil)
         |> assign(:context_menu, nil)
         |> assign(:menu_anchor, nil)
         |> put_flash(:info, "已删除对话")
         |> push_navigate(to: home_path(socket))}
    end
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    _ = Memory.delete_skill(id)

    sk =
      if p = socket.assigns.project do
        Memory.list_skills_for_project(p.id)
      else
        Memory.list_skills_recent(32)
      end

    {:noreply,
     assign(socket,
       skills_sidebar: sk,
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    case Projects.get_project(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "项目不存在")}

      p ->
        if Agents.list_sessions_for_project(p.id) != [] do
          {:noreply, put_flash(socket, :error, "请先移动或删除该项目下的对话")}
        else
          Projects.delete_project(p)

          {:noreply,
           socket
           |> assign(:menu, nil)
           |> assign(:context_menu, nil)
           |> assign(:menu_anchor, nil)
           |> push_navigate(to: ~p"/")}
        end
    end
  end

  def handle_event("rename_project", %{"row_id" => id, "title" => title}, socket) do
    title = String.trim(title || "")

    if title == "" do
      {:noreply, put_flash(socket, :error, "标题不能为空")}
    else
      case Projects.get_project(id) do
        nil ->
          {:noreply, put_flash(socket, :error, "项目不存在")}

        p ->
          {:ok, p} = Projects.update_project(p, %{title: title})
          {:noreply, assign(socket, projects: Projects.list_projects(), project: p, editing: nil)}
      end
    end
  end

  def handle_event("rename_session", %{"row_id" => id, "title" => title}, socket) do
    title = String.trim(title || "")

    if title == "" do
      {:noreply, put_flash(socket, :error, "标题不能为空")}
    else
      case Agents.get_session(id) do
        nil ->
          {:noreply, put_flash(socket, :error, "会话不存在")}

        s ->
          {:ok, s} = Agents.update_session(s, %{title: title})

          {:noreply,
           socket
           |> assign(
             :session,
             if(socket.assigns.session && socket.assigns.session.id == s.id,
               do: s,
               else: socket.assigns.session
             )
           )
           |> assign(:sessions, reload_sessions(socket))
           |> assign(:editing, nil)
           |> assign(:page_title, s.title)}
      end
    end
  end

  def handle_event("start_edit", %{"kind" => kind, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       editing: {kind, id},
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  def handle_event("move_session", %{"id" => sid, "project_id" => pid}, socket) do
    case Agents.get_session(sid) do
      nil ->
        {:noreply, put_flash(socket, :error, "会话不存在")}

      s ->
        {:ok, _} = Agents.move_session_to_project(s, pid)
        {:noreply, socket |> assign(:move_target, nil) |> push_patch(to: ~p"/p/#{pid}")}
    end
  end

  def handle_event("move_skill", %{"id" => skill_id, "project_id" => pid}, socket) do
    case Memory.move_skill_to_project(skill_id, pid) do
      {:ok, _} ->
        sk =
          if p = socket.assigns.project do
            Memory.list_skills_for_project(p.id)
          else
            Memory.list_skills_recent(32)
          end

        {:noreply, assign(socket, skills_sidebar: sk, move_target: nil, menu: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "移动失败")}
    end
  end

  def handle_event("open_skill_editor", %{"id" => id}, socket) do
    case Memory.get_skill(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "技能不存在")}

      sk ->
        body = sk.body || ""

        {:noreply,
         socket
         |> assign(
           skill_editor: %{
             id: sk.id,
             title: sk.title || "",
             body: body,
             keywords: sk.keywords || ""
           },
           menu: nil,
           context_menu: nil,
           menu_anchor: nil
         )
         |> push_event("mde_set_value", %{body: body})}
    end
  end

  def handle_event("open_skill_editor_new", _params, socket) do
    {:noreply,
     socket
     |> assign(
       skill_editor: %{id: nil, title: "", body: "", keywords: ""},
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )
     |> push_event("mde_set_value", %{body: ""})}
  end

  def handle_event("open_skill_import", _params, socket) do
    files = Memory.list_skill_import_files()

    {:noreply,
     assign(socket,
       skill_import_open: true,
       skill_import_files: files,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  def handle_event("close_skill_import", _params, socket) do
    {:noreply, assign(socket, :skill_import_open, false)}
  end

  def handle_event("import_skill_pick", %{"path" => path}, socket) do
    path = String.trim(path || "")

    pid =
      case socket.assigns.project do
        %{id: id} -> id
        _ -> Projects.ensure_default_project().id
      end

    socket =
      case Memory.import_skill_from_file(path, pid) do
        {:ok, _} ->
          socket
          |> put_flash(:info, "已导入技能")
          |> assign(:skill_import_open, false)
          |> assign(:skills_sidebar, reload_skills(socket))

        {:error, :forbidden} ->
          put_flash(socket, :error, "路径不在允许的 skills 目录内")

        _ ->
          put_flash(socket, :error, "导入失败")
      end

    {:noreply, socket}
  end

  def handle_event("close_skill_editor", _params, socket) do
    {:noreply, assign(socket, :skill_editor, nil)}
  end

  def handle_event("save_skill_editor", params, socket) do
    title = params["title"] |> to_string() |> String.trim()
    body = params["body"] |> to_string() |> String.trim()
    keywords = Map.get(params, "keywords", "")
    id_str = Map.get(params, "skill_id", "") |> to_string() |> String.trim()

    if title == "" or body == "" do
      {:noreply, put_flash(socket, :error, "标题与正文不能为空")}
    else
      kw = keywords |> to_string() |> String.trim()

      socket =
        case id_str do
          "" ->
            pid =
              case socket.assigns.project do
                %{id: x} -> x
                _ -> FluxClaw.Projects.ensure_default_project().id
              end

            case Memory.create_skill(%{
                   title: title,
                   body: body,
                   keywords: kw,
                   project_id: pid,
                   source: "manual"
                 }) do
              {:ok, _} ->
                socket
                |> put_flash(:info, "技能已创建")
                |> assign(:skill_editor, nil)
                |> assign(:skills_sidebar, reload_skills(socket))

              {:error, _} ->
                put_flash(socket, :error, "保存失败")
            end

          id ->
            case Memory.get_skill(id) do
              nil ->
                put_flash(socket, :error, "技能不存在")

              sk ->
                case Memory.update_skill(sk, %{title: title, body: body, keywords: kw}) do
                  {:ok, _} ->
                    socket
                    |> put_flash(:info, "已保存")
                    |> assign(:skill_editor, nil)
                    |> assign(:skills_sidebar, reload_skills(socket))

                  {:error, _} ->
                    put_flash(socket, :error, "保存失败")
                end
            end
        end

      {:noreply, socket}
    end
  end

  def handle_event("external_link_click", %{"url" => url, "title" => title}, socket) do
    url = String.trim(url || "")

    if url == "" do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         external_link_prompt: %{url: url, title: String.slice(title || "", 0, 200)}
       )}
    end
  end

  def handle_event("cancel_external_link", _params, socket) do
    {:noreply, assign(socket, :external_link_prompt, nil)}
  end

  def handle_event("confirm_external_link", _params, socket) do
    case socket.assigns.external_link_prompt do
      nil ->
        {:noreply, socket}

      %{url: url} = p ->
        socket =
          socket
          |> assign(:external_link_prompt, nil)
          |> push_event("open_external", %{url: url, title: Map.get(p, :title) || ""})

        {:noreply, socket}
    end
  end

  def handle_event("settings_pick_model", %{"picked" => picked}, socket) do
    picked = String.trim(picked || "")
    form = Map.put(socket.assigns.settings_form, "model", picked)
    {:noreply, assign(socket, :settings_form, form)}
  end

  def handle_event("settings_pick_model", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("refresh_models", _params, socket) do
    case FluxClaw.LLM.OpenAI.list_models() do
      {:ok, ids} ->
        {:noreply,
         socket
         |> assign(:settings_models, ids)
         |> put_flash(:info, "已更新模型列表（#{length(ids)} 个）")}

      {:error, :missing_api_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "无法拉取模型：请填写 API Key 并保存，或设置环境变量 OPENAI_API_KEY"
         )}

      {:error, {:http, st, body}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "拉取模型列表失败（HTTP #{st}）：#{short_error_body(body)}"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "拉取模型列表失败：#{inspect(reason)}")}
    end
  end

  def handle_event("save_settings", params, socket) do
    base_url = Map.get(params, "base_url", "") || ""
    model = Map.get(params, "model", "") || ""
    max_steps_str = Map.get(params, "max_steps", "") || ""
    temp_str = Map.get(params, "temperature", "") || ""
    top_p_str = Map.get(params, "top_p", "") || ""
    top_k_str = Map.get(params, "top_k", "") || ""
    cache_root = Map.get(params, "cache_root", "") || ""
    ext = Map.get(params, "external_skills", "") || ""
    internal = Map.get(params, "internal_skills", "") || ""
    hist = Map.get(params, "history_root", "") || ""
    mem = Map.get(params, "memory_root", "") || ""
    api_key_in = params |> Map.get("api_key", "") |> to_string() |> String.trim()
    self_evolve = Map.get(params, "self_evolve") == "true"
    crystallize_skills = Map.get(params, "crystallize_skills") == "true"

    crystallize_mode =
      case Map.get(params, "crystallize_mode", "auto") do
        "confirm" -> :confirm
        _ -> :auto
      end

    model = String.trim(model)

    prev_llm_kw =
      case Application.get_env(:flux_claw, :llm, []) do
        kw when is_list(kw) -> kw
        _ -> []
      end

    base_url =
      case String.trim(base_url) do
        "" -> prev_llm_kw[:base_url] || "https://api.openai.com/v1"
        u -> String.trim_trailing(u, "/")
      end

    ext = String.trim(ext)
    internal = String.trim(internal)
    hist = String.trim(hist)
    mem = String.trim(mem)
    cache_root = String.trim(cache_root)

    max_steps =
      case Integer.parse(String.trim(max_steps_str)) do
        {i, _} -> i
        :error -> 32
      end

    temp_f = parse_optional_float(temp_str)
    top_p_f = parse_optional_float(top_p_str)
    top_k_i = parse_optional_int(top_k_str)

    openai_updates =
      %{"model" => model, "base_url" => base_url}
      |> then(fn m -> if temp_f != nil, do: Map.put(m, "temperature", temp_f), else: m end)
      |> then(fn m -> if top_p_f != nil, do: Map.put(m, "top_p", top_p_f), else: m end)
      |> then(fn m -> if top_k_i != nil, do: Map.put(m, "top_k", top_k_i), else: m end)
      |> then(fn m -> if api_key_in != "", do: Map.put(m, "api_key", api_key_in), else: m end)

    cache_updates =
      %{
        "external_skills" => ext,
        "internal_skills" => internal,
        "history_root" => hist,
        "memory_root" => mem
      }
      |> then(fn m -> if cache_root != "", do: Map.put(m, "cache_root", cache_root), else: m end)

    merged =
      FluxClaw.ConfigLoader.merge_save!(%{
        "openai" => openai_updates,
        "agents" => %{
          "max_steps" => max_steps,
          "self_evolve" => self_evolve,
          "crystallize_skills" => crystallize_skills,
          "crystallize_mode" => Atom.to_string(crystallize_mode)
        },
        "cache_paths" => cache_updates
      })

    llm =
      prev_llm_kw
      |> Keyword.put(:model, model)
      |> Keyword.put(:base_url, base_url)
      |> Keyword.put(:temperature, temp_f)
      |> Keyword.put(:top_p, top_p_f)
      |> Keyword.put(:top_k, top_k_i)

    llm =
      if api_key_in != "" do
        Keyword.put(llm, :api_key, api_key_in)
      else
        llm
      end

    Application.put_env(:flux_claw, :llm, llm)

    prev_agents = Application.get_env(:flux_claw, :agents, [])

    prev_agents =
      prev_agents
      |> Keyword.put(:max_steps, max_steps)
      |> Keyword.put(:self_evolve, self_evolve)
      |> Keyword.put(:crystallize_skills, crystallize_skills)
      |> Keyword.put(:crystallize_mode, crystallize_mode)

    Application.put_env(:flux_claw, :agents, prev_agents)

    default_cache = FluxClaw.ConfigLoader.default_cache_root()
    resolved_root = if cache_root != "", do: cache_root, else: default_cache
    resolved_root = Path.expand(resolved_root)

    paths = [
      cache_root: resolved_root,
      external_skills: ext,
      internal_skills: internal,
      history_root: hist,
      memory_root: mem
    ]

    Application.put_env(:flux_claw, :cache_paths, paths)

    for {_k, p} <- paths, is_binary(p), p != "", do: File.mkdir_p!(p)

    _ = merged

    {:noreply,
     socket
     |> put_flash(
       :info,
       "已保存到 #{FluxClaw.ConfigLoader.config_path()}；下次打开设置将从配置文件加载（含 API Key）"
     )
     |> assign(:settings_open, false)
     |> assign(:settings_form, settings_form_defaults())}
  end

  def handle_event("accept_skill_proposal", _params, socket) do
    case socket.assigns.skill_proposal do
      nil ->
        {:noreply, socket}

      attrs ->
        case Memory.create_skill(attrs) do
          {:ok, _} ->
            sk =
              if p = socket.assigns.project do
                Memory.list_skills_for_project(p.id)
              else
                Memory.list_skills_recent(32)
              end

            sid = socket.assigns.session && socket.assigns.session.id

            if is_binary(sid) do
              t = Map.get(attrs, :title) || Map.get(attrs, "title") || ""

              _ = Memory.append_evolution_log_line(sid, "accepted skill: #{t}")
            end

            {:noreply,
             socket
             |> assign(:skill_proposal, nil)
             |> assign(:skills_sidebar, sk)
             |> put_flash(:info, "技能已保存")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "保存技能失败")}
        end
    end
  end

  def handle_event("dismiss_skill_proposal", _params, socket) do
    {:noreply, assign(socket, :skill_proposal, nil)}
  end

  def handle_event("stop_agent", _params, socket) do
    case socket.assigns.session do
      %{id: sid} ->
        stop_session_worker(sid)

        {:noreply,
         socket
         |> assign(:agent_busy, false)
         |> assign(:draft_assistant, nil)
         |> assign(:draft_reasoning, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.session) ->
        case socket.assigns.project do
          nil ->
            {:noreply, put_flash(socket, :error, "请先选择项目")}

          %{id: pid} ->
            case Agents.create_session(%{project_id: pid, title: "新对话"}) do
              {:ok, s} ->
                case Agents.append_message(s.id, %{role: "user", content: text}) do
                  {:ok, _} ->
                    _ = Orchestrator.ensure_worker(s.id)
                    {:noreply, push_patch(socket, to: ~p"/chat/#{s.id}")}

                  {:error, _} ->
                    {:noreply, put_flash(socket, :error, "发送失败")}
                end

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "创建对话失败")}
            end
        end

      true ->
        Orchestrator.send_message(socket.assigns.session.id, text)
        {:noreply, assign(socket, :agent_busy, true)}
    end
  end

  def handle_event("answer_user", %{"ref" => ref_str, "text" => text}, socket) do
    text = String.trim(text)
    ref = String.to_integer(ref_str)

    socket =
      if text != "" && socket.assigns.session do
        Orchestrator.reply_ask_user(socket.assigns.session.id, ref, text)
        assign(socket, :agent_busy, true)
      else
        socket
      end

    {:noreply, assign(socket, :pending_ask, nil)}
  end

  defp parse_optional_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_optional_float(_), do: nil

  defp parse_optional_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_optional_int(_), do: nil

  defp short_error_body(body) when is_binary(body), do: String.slice(body, 0, 120)
  defp short_error_body(body), do: String.slice(inspect(body), 0, 120)

  defp reload_skills(socket) do
    case socket.assigns.project do
      %{id: pid} -> Memory.list_skills_for_project(pid)
      _ -> Memory.list_skills_recent(32)
    end
  end

  defp home_path(socket) do
    case socket.assigns.project do
      %{id: pid} -> ~p"/p/#{pid}"
      _ -> ~p"/"
    end
  end

  defp reload_sessions(socket) do
    case socket.assigns.project do
      %{id: pid} -> Agents.list_sessions_for_project(pid)
      _ -> []
    end
  end

  @impl true
  def handle_info({:user, text}, socket) do
    {:noreply, push_log(socket, {:user, text})}
  end

  def handle_info({:session_title_updated, title}, socket) do
    sess = socket.assigns.session

    socket =
      if sess do
        socket
        |> assign(:session, %{sess | title: title})
        |> assign(:page_title, title)
        |> assign(:sessions, reload_sessions(socket))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:reasoning_delta, text}, socket) do
    cur = socket.assigns.draft_reasoning || ""
    {:noreply, assign(socket, :draft_reasoning, cur <> text)}
  end

  def handle_info({:reasoning_done, text}, socket) do
    socket =
      socket
      |> assign(:draft_reasoning, nil)
      |> push_log({:reasoning, text})

    {:noreply, socket}
  end

  def handle_info({:assistant_delta, text}, socket) do
    cur = socket.assigns.draft_assistant || ""
    {:noreply, assign(socket, :draft_assistant, cur <> text)}
  end

  def handle_info({:assistant_done, text}, socket) do
    log = socket.assigns.log ++ [{:assistant, text}]

    socket =
      socket
      |> assign(:log, log)
      |> assign(:draft_assistant, nil)

    socket =
      if socket.assigns.session do
        assign(
          socket,
          :checkpoints,
          Memory.list_checkpoints_for_session(socket.assigns.session.id)
        )
      else
        socket
      end

    socket = sync_agent_busy_from_db(socket)

    {:noreply, socket}
  end

  def handle_info({:tool_start, name, args}, socket) do
    {:noreply, socket |> push_log({:tool_start, name, args}) |> assign(:agent_busy, true)}
  end

  def handle_info({:tool_done, id, name, text}, socket) do
    {:noreply, socket |> push_log({:tool_done, id, name, text}) |> assign(:agent_busy, true)}
  end

  def handle_info({:ask_user, ref, question}, socket) do
    {:noreply,
     socket
     |> assign(:pending_ask, %{ref: ref, question: question})
     |> assign(:agent_busy, false)}
  end

  def handle_info({:skill_proposal, attrs}, socket) do
    {:noreply, assign(socket, :skill_proposal, attrs)}
  end

  def handle_info({:skill_saved, _title}, socket) do
    sk =
      if p = socket.assigns.project do
        Memory.list_skills_for_project(p.id)
      else
        Memory.list_skills_recent(32)
      end

    {:noreply, assign(socket, :skills_sidebar, sk)}
  end

  def handle_info({:error, reason}, socket) do
    {:noreply, socket |> put_flash(:error, inspect(reason)) |> assign(:agent_busy, false)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp push_log(socket, entry) do
    assign(socket, :log, socket.assigns.log ++ [entry])
  end

  defp sync_agent_busy_from_db(socket) do
    case socket.assigns.session do
      %{id: sid} -> assign(socket, :agent_busy, composer_agent_busy?(sid))
      _ -> assign(socket, :agent_busy, false)
    end
  end

  # 仅当「库里的对话还需要 agent 继续」且「本会话 worker 仍在跑」时显示停止。
  # 用户点停止会停掉 worker，此时即使 needs_resume? 仍为 true 也应显示发送，避免历史会话/中止后卡死。
  defp composer_agent_busy?(session_id) when is_binary(session_id) do
    AgentWorker.needs_resume?(session_id) && worker_running?(session_id)
  end

  defp composer_agent_busy?(_), do: false

  defp worker_running?(session_id) when is_binary(session_id) do
    match?([{_pid, _}], Registry.lookup(FluxClaw.Agents.Registry, session_id))
  end

  defp worker_running?(_), do: false

  defp stop_session_worker(session_id) do
    case Registry.lookup(FluxClaw.Agents.Registry, session_id) do
      [{pid, _}] ->
        _ = GenServer.stop(pid, :shutdown, 15_000)
        :ok

      [] ->
        :ok
    end
  end

  defp grouped_log_entries(log) do
    Enum.reduce(log, [], fn entry, acc ->
      case entry do
        {:tool_start, _, _} -> append_tool_chunk(acc, entry)
        {:tool_done, _, _, _} -> append_tool_chunk(acc, entry)
        _ -> acc ++ [entry]
      end
    end)
  end

  defp append_tool_chunk([], e), do: [{:tools, [e]}]

  defp append_tool_chunk(acc, e) do
    case List.last(acc) do
      {:tools, chunk} ->
        List.replace_at(acc, length(acc) - 1, {:tools, chunk ++ [e]})

      _ ->
        acc ++ [{:tools, [e]}]
    end
  end

  defp context_menu_style(%{top: t, right: r}) do
    left = max(8, r - 208)
    "left: #{left}px; top: #{t}px; transform: translateY(calc(-100% - 6px));"
  end

  defp md_html(text) when is_binary(text) and text != "" do
    Earmark.as_html!(text, gfm: true, breaks: true)
  rescue
    _ ->
      text |> Plug.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp md_html(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} variant={:bare}>
      <div class="flex h-dvh flex-col bg-zinc-100 text-zinc-900 overflow-hidden [[data-theme=dark]_&]:bg-zinc-950 [[data-theme=dark]_&]:text-zinc-100">
        <div class="flex flex-1 min-h-0 relative">
          <div
            :if={@sidebar_open}
            class="fixed inset-0 z-40 bg-black/40 lg:hidden"
            phx-click="toggle_sidebar"
          >
          </div>

          <aside
            class={[
              "fixed lg:static inset-y-0 left-0 z-50 flex w-[min(17.5rem,88vw)] flex-col border-r border-zinc-200/80 bg-white [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900 transition-transform duration-200 lg:translate-x-0",
              if(@sidebar_open, do: "translate-x-0", else: "-translate-x-full")
            ]}
            id="sidebar-root"
          >
            <div class="flex h-12 items-center gap-2 border-b border-zinc-200/80 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
              <span class="font-semibold tracking-tight text-[15px]">FluxClaw</span>
            </div>

            <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
              <section class="flex flex-col min-h-0 border-b border-zinc-100 [[data-theme=dark]_&]:border-zinc-800 shrink-0 max-h-[32vh]">
                <div class="flex items-center gap-1 px-2 py-2 shrink-0">
                  <button
                    type="button"
                    phx-click="toggle_nav"
                    phx-value-section="projects"
                    class="flex flex-1 min-w-0 items-center gap-2 text-left rounded-lg hover:bg-zinc-50 [[data-theme=dark]_&]:hover:bg-zinc-800/60 px-1 py-0.5"
                    id="nav-toggle-projects"
                  >
                    <.icon
                      name="hero-chevron-right"
                      class={[
                        "size-4 text-zinc-400 shrink-0 transition-transform",
                        @nav_open["projects"] && "rotate-90"
                      ]}
                    />
                    <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 truncate">
                      项目
                    </span>
                  </button>
                  <button
                    type="button"
                    phx-click="new_project"
                    class="text-xs text-emerald-600 hover:text-emerald-700 font-medium shrink-0 px-1"
                  >
                    + 新建
                  </button>
                </div>
                <div :if={@nav_open["projects"]} class="flex-1 min-h-0 overflow-y-auto px-2 pb-2">
                  <%= for p <- @projects do %>
                    <div class="group flex items-center gap-0.5 rounded-lg hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800/80">
                      <.link
                        patch={~p"/p/#{p.id}"}
                        class={[
                          "flex-1 min-w-0 px-2 py-1.5 text-sm rounded-lg transition-colors",
                          @project && @project.id == p.id &&
                            "bg-zinc-200/90 font-medium [[data-theme=dark]_&]:bg-zinc-800"
                        ]}
                      >
                        <span class="truncate block">{p.title}</span>
                      </.link>
                      <button
                        type="button"
                        id={"sidebar-ctx-project-#{p.id}"}
                        phx-hook="SidebarContextMenu"
                        data-menu-type="project"
                        data-menu-id={p.id}
                        class="p-1.5 rounded-md text-zinc-500 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700 shrink-0"
                        aria-label="菜单"
                      >
                        <.icon name="hero-ellipsis-vertical" class="size-4" />
                      </button>
                    </div>
                  <% end %>
                </div>
              </section>

              <section class="flex flex-col min-h-0 border-b border-zinc-100 [[data-theme=dark]_&]:border-zinc-800 flex-1 max-h-[34vh]">
                <div class="flex items-center gap-1 px-2 py-2 shrink-0">
                  <button
                    type="button"
                    phx-click="toggle_nav"
                    phx-value-section="chats"
                    class="flex flex-1 min-w-0 items-center gap-2 text-left rounded-lg hover:bg-zinc-50 [[data-theme=dark]_&]:hover:bg-zinc-800/60 px-1 py-0.5"
                    id="nav-toggle-chats"
                  >
                    <.icon
                      name="hero-chevron-right"
                      class={[
                        "size-4 text-zinc-400 shrink-0 transition-transform",
                        @nav_open["chats"] && "rotate-90"
                      ]}
                    />
                    <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 truncate">
                      对话
                    </span>
                  </button>
                  <button
                    type="button"
                    phx-click="new_chat"
                    class="text-xs text-emerald-600 hover:text-emerald-700 font-medium shrink-0 px-1"
                  >
                    + 新建
                  </button>
                </div>
                <div :if={@nav_open["chats"]} class="flex-1 min-h-0 overflow-y-auto px-2 pb-2">
                  <%= for s <- @sessions do %>
                    <div class="group flex items-center gap-0.5 rounded-lg hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800/80">
                      <.link
                        patch={~p"/chat/#{s.id}"}
                        class={[
                          "flex-1 min-w-0 px-2 py-1.5 text-sm rounded-lg transition-colors",
                          @session && @session.id == s.id &&
                            "bg-zinc-200/90 font-medium [[data-theme=dark]_&]:bg-zinc-800"
                        ]}
                      >
                        <span class="truncate block">{s.title}</span>
                        <span class="text-[10px] text-zinc-400">
                          {Calendar.strftime(s.inserted_at, "%m-%d %H:%M")}
                        </span>
                      </.link>
                      <button
                        type="button"
                        id={"sidebar-ctx-session-#{s.id}"}
                        phx-hook="SidebarContextMenu"
                        data-menu-type="session"
                        data-menu-id={s.id}
                        class="p-1.5 rounded-md text-zinc-500 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700 shrink-0"
                        aria-label="菜单"
                      >
                        <.icon name="hero-ellipsis-vertical" class="size-4" />
                      </button>
                    </div>
                  <% end %>
                  <%= if @sessions == [] do %>
                    <p class="text-xs text-zinc-400 px-2 py-3">当前项目下暂无对话</p>
                  <% end %>
                </div>
              </section>

              <section class="flex flex-col min-h-0 flex-1 max-h-[34vh]">
                <div class="flex items-center gap-1 px-2 py-2 shrink-0">
                  <button
                    type="button"
                    phx-click="toggle_nav"
                    phx-value-section="skills"
                    class="flex flex-1 min-w-0 items-center gap-2 text-left rounded-lg hover:bg-zinc-50 [[data-theme=dark]_&]:hover:bg-zinc-800/60 px-1 py-0.5"
                    id="nav-toggle-skills"
                  >
                    <.icon
                      name="hero-chevron-right"
                      class={[
                        "size-4 text-zinc-400 shrink-0 transition-transform",
                        @nav_open["skills"] && "rotate-90"
                      ]}
                    />
                    <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 truncate">
                      技能 (L3)
                    </span>
                  </button>
                  <div class="flex items-center gap-1 shrink-0">
                    <button
                      type="button"
                      phx-click="open_skill_import"
                      class="text-xs text-sky-600 hover:text-sky-700 font-medium px-1"
                    >
                      导入
                    </button>
                    <button
                      type="button"
                      phx-click="open_skill_editor_new"
                      class="text-xs text-emerald-600 hover:text-emerald-700 font-medium px-1"
                    >
                      + 新建
                    </button>
                  </div>
                </div>
                <div :if={@nav_open["skills"]} class="flex-1 min-h-0 overflow-y-auto px-2 pb-2">
                  <%= for sk <- @skills_sidebar do %>
                    <div class="group flex items-start gap-0.5 py-1 border-b border-zinc-100 last:border-0 [[data-theme=dark]_&]:border-zinc-800">
                      <span class="truncate flex-1 text-xs" title={sk.title}>{sk.title}</span>
                      <button
                        type="button"
                        id={"sidebar-ctx-skill-#{sk.id}"}
                        phx-hook="SidebarContextMenu"
                        data-menu-type="skill"
                        data-menu-id={sk.id}
                        class="p-1 rounded text-zinc-500 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700 shrink-0"
                        aria-label="菜单"
                      >
                        <.icon name="hero-ellipsis-vertical" class="size-3.5" />
                      </button>
                    </div>
                  <% end %>
                </div>
              </section>

              <section class="flex flex-col min-h-0 flex-1 max-h-[28vh] border-t border-zinc-100 [[data-theme=dark]_&]:border-zinc-800">
                <div class="flex items-center gap-1 px-2 py-2 shrink-0">
                  <button
                    type="button"
                    phx-click="toggle_nav"
                    phx-value-section="memory"
                    class="flex flex-1 min-w-0 items-center gap-2 text-left rounded-lg hover:bg-zinc-50 [[data-theme=dark]_&]:hover:bg-zinc-800/60 px-1 py-0.5"
                    id="nav-toggle-memory"
                  >
                    <.icon
                      name="hero-chevron-right"
                      class={[
                        "size-4 text-zinc-400 shrink-0 transition-transform",
                        @nav_open["memory"] && "rotate-90"
                      ]}
                    />
                    <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 truncate">
                      Memory (.md)
                    </span>
                  </button>
                </div>
                <div :if={@nav_open["memory"]} class="flex-1 min-h-0 overflow-y-auto px-2 pb-2">
                  <%= for f <- @memory_doc_files do %>
                    <div class="py-1 border-b border-zinc-100 last:border-0 [[data-theme=dark]_&]:border-zinc-800">
                      <span
                        class="text-[11px] text-zinc-600 [[data-theme=dark]_&]:text-zinc-400 truncate block"
                        title={f.path}
                      >
                        {f.name}
                      </span>
                    </div>
                  <% end %>
                  <%= if @memory_doc_files == [] do %>
                    <p class="text-[11px] text-zinc-400 px-1 py-2">memory 目录下暂无文档</p>
                  <% end %>
                </div>
              </section>
            </div>

            <div class="border-t border-zinc-200/80 p-2 flex items-center justify-between gap-2 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
              <button
                type="button"
                phx-click="toggle_settings"
                class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
              >
                <.icon name="hero-cog-6-tooth" class="size-5" /> 设置
              </button>
              <button
                type="button"
                id="fluxclaw-theme-toggle"
                phx-hook="ThemeToggle"
                class="rounded-lg border border-zinc-200 p-2 text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="切换浅色 / 深色"
              >
                <span data-theme-icon="moon" class="block">
                  <.icon name="hero-moon" class="size-5 text-indigo-500" />
                </span>
                <span data-theme-icon="sun" class="hidden">
                  <.icon name="hero-sun" class="size-5 text-amber-500" />
                </span>
              </button>
            </div>
          </aside>

          <%= if @context_menu && @menu_anchor do %>
            <div class="fixed inset-0 z-[580]" phx-click="close_menu"></div>
            <div
              class="fixed z-[590] w-52 max-h-[min(70vh,24rem)] overflow-y-auto rounded-xl border border-zinc-200 bg-white py-1 shadow-2xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900"
              style={context_menu_style(@menu_anchor)}
            >
              <%= case @context_menu do %>
                <% {"project", id} -> %>
                  <button
                    type="button"
                    phx-click="start_edit"
                    phx-value-kind="project"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    重命名
                  </button>
                  <button
                    type="button"
                    phx-click="delete_project"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm text-red-600 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    删除
                  </button>
                <% {"session", id} -> %>
                  <button
                    type="button"
                    phx-click="start_edit"
                    phx-value-kind="session"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    重命名
                  </button>
                  <button
                    type="button"
                    phx-click="open_move"
                    phx-value-type="session"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    移动到项目…
                  </button>
                  <button
                    type="button"
                    phx-click="delete_session"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm text-red-600 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    删除
                  </button>
                <% {"skill", id} -> %>
                  <button
                    type="button"
                    phx-click="open_skill_editor"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    编辑
                  </button>
                  <button
                    type="button"
                    phx-click="open_move"
                    phx-value-type="skill"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    移动到项目…
                  </button>
                  <button
                    type="button"
                    phx-click="delete_skill"
                    phx-value-id={id}
                    class="block w-full px-3 py-2 text-left text-sm text-red-600 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  >
                    删除
                  </button>
                <% _ -> %>
              <% end %>
            </div>
          <% end %>

          <%= if @skill_editor do %>
            <div
              class="fixed inset-0 z-[52] bg-black/40 lg:left-[min(17.5rem,88vw)]"
              phx-click="close_skill_editor"
            >
            </div>
            <aside
              class={[
                "fixed top-0 bottom-0 z-[53] flex w-[min(52rem,100vw)] flex-col border-r border-zinc-200 bg-white shadow-2xl transition-transform duration-300 ease-out [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900",
                "left-0 lg:left-[min(17.5rem,88vw)] translate-x-0"
              ]}
              id="skill-editor-drawer"
            >
              <div class="flex h-12 items-center justify-between border-b border-zinc-200 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
                <span class="font-semibold text-sm">
                  {if(@skill_editor.id, do: "编辑技能", else: "新建技能")}
                </span>
                <button
                  type="button"
                  phx-click="close_skill_editor"
                  class="rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                  aria-label="关闭"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
              <form
                phx-submit="save_skill_editor"
                id="skill-editor-form"
                class="flex flex-1 flex-col min-h-0 p-3 gap-3"
              >
                <input type="hidden" name="skill_id" value={@skill_editor.id || ""} />
                <div>
                  <label class="block text-xs font-medium text-zinc-500 mb-1" for="skill-editor-title">
                    标题
                  </label>
                  <input
                    type="text"
                    name="title"
                    id="skill-editor-title"
                    value={@skill_editor.title}
                    required
                    class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
                  />
                </div>
                <div>
                  <label
                    class="block text-xs font-medium text-zinc-500 mb-1"
                    for="skill-editor-keywords"
                  >
                    关键词（可选）
                  </label>
                  <input
                    type="text"
                    name="keywords"
                    id="skill-editor-keywords"
                    value={@skill_editor.keywords}
                    class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
                  />
                </div>
                <div class="flex-1 flex flex-col min-h-0 min-h-[22rem]">
                  <label class="block text-xs font-medium text-zinc-500 mb-1" for="skill-editor-body">
                    正文（Markdown，工具栏支持预览 / 分栏）
                  </label>
                  <div
                    id="skill-mde-mount"
                    phx-update="ignore"
                    phx-hook="MarkdownEditor"
                    class="flex-1 min-h-[18rem] rounded-lg border border-zinc-200 overflow-hidden [[data-theme=dark]_&]:border-zinc-700"
                  >
                    <textarea
                      name="body"
                      id="skill-editor-body"
                      class="w-full min-h-[16rem] text-sm font-mono"
                    ></textarea>
                  </div>
                </div>
                <div class="flex gap-2 justify-end shrink-0 pt-1">
                  <button
                    type="button"
                    phx-click="close_skill_editor"
                    class="rounded-lg border border-zinc-300 px-4 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600"
                  >
                    取消
                  </button>
                  <button
                    type="submit"
                    class="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
                  >
                    保存
                  </button>
                </div>
              </form>
            </aside>
          <% end %>

          <main class="relative flex flex-1 flex-col min-w-0 min-h-0 bg-white [[data-theme=dark]_&]:bg-zinc-950">
            <header class="flex h-12 items-center gap-2 border-b border-zinc-200/80 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
              <button
                type="button"
                phx-click="toggle_sidebar"
                class="rounded-lg p-2 text-zinc-600 hover:bg-zinc-100 lg:hidden [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
                aria-label="菜单"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </button>
              <div class="flex-1 min-w-0">
                <h1 class="text-[15px] font-semibold truncate">
                  {(@session && @session.title) || (@project && @project.title) || "选择项目或对话"}
                </h1>
              </div>
            </header>

            <%= if @skill_proposal do %>
              <div class="shrink-0 border-b border-amber-200/80 bg-amber-50 px-4 py-3 text-sm [[data-theme=dark]_&]:border-amber-900/50 [[data-theme=dark]_&]:bg-amber-950/40">
                <p class="font-medium text-amber-900 [[data-theme=dark]_&]:text-amber-200">
                  建议保存新技能（需确认）
                </p>
                <p class="text-zinc-700 mt-1 truncate [[data-theme=dark]_&]:text-zinc-300">
                  {@skill_proposal.title}
                </p>
                <div class="mt-2 flex gap-2">
                  <button
                    type="button"
                    phx-click="accept_skill_proposal"
                    class="rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700"
                  >
                    接受并保存
                  </button>
                  <button
                    type="button"
                    phx-click="dismiss_skill_proposal"
                    class="rounded-lg border border-zinc-300 px-3 py-1.5 text-xs [[data-theme=dark]_&]:border-zinc-600"
                  >
                    忽略
                  </button>
                </div>
              </div>
            <% end %>

            <%= if @move_target do %>
              <.move_project_modal
                projects={@projects}
                move_target={@move_target}
                current_project={@project}
              />
            <% end %>

            <%= if @editing do %>
              <.edit_modal editing={@editing} projects={@projects} sessions={@sessions} />
            <% end %>

            <%= if @settings_open do %>
              <.settings_modal form={@settings_form} model_options={@settings_models} />
            <% end %>

            <%= if @skill_import_open do %>
              <div class="fixed inset-0 z-[555] flex items-center justify-center p-4">
                <div class="absolute inset-0 bg-black/50" phx-click="close_skill_import"></div>
                <div class="relative z-10 flex max-h-[min(80vh,32rem)] w-full max-w-lg flex-col rounded-2xl border border-zinc-200 bg-white shadow-xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
                  <div class="flex items-center justify-between border-b border-zinc-200 px-4 py-3 [[data-theme=dark]_&]:border-zinc-800">
                    <span class="text-sm font-semibold">从 skills 目录导入</span>
                    <button
                      type="button"
                      phx-click="close_skill_import"
                      class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                      aria-label="关闭"
                    >
                      <.icon name="hero-x-mark" class="size-5" />
                    </button>
                  </div>
                  <div class="flex-1 min-h-0 overflow-y-auto p-2">
                    <%= if @skill_import_files == [] do %>
                      <p class="text-sm text-zinc-500 px-2 py-4 text-center">
                        未找到 .md 文件。请在设置中配置内部 / 外部 skills 目录。
                      </p>
                    <% else %>
                      <%= for f <- @skill_import_files do %>
                        <button
                          type="button"
                          phx-click="import_skill_pick"
                          phx-value-path={f.path}
                          class="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800 truncate"
                          title={f.path}
                        >
                          {f.name}
                        </button>
                      <% end %>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @external_link_prompt do %>
              <div class="fixed inset-0 z-[75] flex items-center justify-center p-4">
                <div class="absolute inset-0 bg-black/50" phx-click="cancel_external_link"></div>
                <div class="relative z-10 w-full max-w-md rounded-2xl border border-zinc-200 bg-white p-5 shadow-xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
                  <p class="text-sm font-medium text-zinc-800 [[data-theme=dark]_&]:text-zinc-100">
                    在浏览器新标签页中打开外部链接？
                  </p>
                  <p class="mt-2 text-xs text-zinc-500 break-all">
                    {@external_link_prompt.url}
                  </p>
                  <%= if (Map.get(@external_link_prompt, :title) || "") != "" do %>
                    <p class="mt-1 text-sm text-zinc-600 [[data-theme=dark]_&]:text-zinc-300 truncate">
                      {Map.get(@external_link_prompt, :title)}
                    </p>
                  <% end %>
                  <div class="mt-4 flex gap-2 justify-end">
                    <button
                      type="button"
                      phx-click="cancel_external_link"
                      class="rounded-lg border border-zinc-300 px-4 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600"
                    >
                      取消
                    </button>
                    <button
                      type="button"
                      phx-click="confirm_external_link"
                      class="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
                    >
                      打开链接
                    </button>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @session do %>
              <%= if @checkpoints != [] do %>
                <div class="shrink-0 border-b border-zinc-100 bg-zinc-50/80 px-3 py-2 text-xs max-h-20 overflow-y-auto [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/50">
                  <span class="font-medium text-zinc-500">检查点</span>
                  <ul class="mt-1 space-y-0.5 text-zinc-600 [[data-theme=dark]_&]:text-zinc-400">
                    <%= for c <- Enum.take(@checkpoints, 5) do %>
                      <li class="truncate">
                        {c.label || "checkpoint"} · {Calendar.strftime(c.inserted_at, "%H:%M")}
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <div
                id="chat-scroll"
                phx-hook="ChatScroll"
                class="flex-1 overflow-y-auto px-3 py-6 space-y-5 scroll-smooth max-w-[56rem] mx-auto w-full"
                data-external-link-event="external_link_click"
              >
                <%= for entry <- grouped_log_entries(@log) do %>
                  <%= case entry do %>
                    <% {:tools, items} -> %>
                      <.tools_flow_block items={items} />
                    <% _ -> %>
                      <.chat_bubble entry={entry} />
                  <% end %>
                <% end %>

                <%= if @draft_reasoning && @draft_reasoning != "" do %>
                  <details class="group rounded-xl border border-violet-200/80 bg-violet-50/90 [[data-theme=dark]_&]:border-violet-900/50 [[data-theme=dark]_&]:bg-violet-950/30">
                    <summary class="cursor-pointer select-none list-none flex items-center gap-2 px-4 py-2.5 text-xs font-medium text-violet-700 [[data-theme=dark]_&]:text-violet-300 marker:content-none">
                      <.icon
                        name="hero-chevron-right"
                        class="size-4 shrink-0 transition-transform group-open:rotate-90"
                      />
                      <.icon name="hero-sparkles" class="size-4" /> 思考中…（点击展开）
                    </summary>
                    <div class="chat-md border-t border-violet-200/60 px-4 py-3 text-sm text-zinc-800 [[data-theme=dark]_&]:border-violet-900/40 [[data-theme=dark]_&]:text-zinc-200">
                      {raw(md_html(@draft_reasoning))}
                    </div>
                  </details>
                <% end %>

                <%= if @draft_assistant && @draft_assistant != "" do %>
                  <div class="flex justify-start">
                    <div class="chat-md w-full rounded-2xl border border-zinc-200 bg-zinc-50 px-4 py-3 [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/60">
                      <div class="flex items-center gap-2 text-xs text-zinc-500 mb-2">
                        <span class="inline-block size-2 rounded-full bg-emerald-500 animate-pulse">
                        </span>
                        正在输出…
                      </div>
                      <div class="chat-md text-[15px] leading-relaxed">
                        {raw(md_html(@draft_assistant))}
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

              <%= if @pending_ask do %>
                <div class="shrink-0 border-t border-amber-300/50 bg-amber-50/90 px-4 py-3 [[data-theme=dark]_&]:border-amber-900/40 [[data-theme=dark]_&]:bg-amber-950/30">
                  <p class="text-sm font-medium">需要你的确认</p>
                  <p class="text-sm mt-1 whitespace-pre-wrap text-zinc-700 [[data-theme=dark]_&]:text-zinc-300">
                    {@pending_ask.question}
                  </p>
                  <form
                    id="ask-user-form"
                    phx-submit="answer_user"
                    class="mt-3 flex flex-col sm:flex-row gap-2"
                  >
                    <input type="hidden" name="ref" value={@pending_ask.ref} />
                    <textarea
                      name="text"
                      id="ask-user-text"
                      rows="2"
                      class="flex-1 rounded-xl border border-zinc-300 bg-white px-3 py-2 text-sm min-h-[2.5rem] [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-900"
                      placeholder="输入回复…"
                    ></textarea>
                    <button
                      type="submit"
                      class="rounded-xl bg-amber-600 px-4 py-2 text-sm font-medium text-white hover:bg-amber-700 shrink-0"
                    >
                      提交
                    </button>
                  </form>
                </div>
              <% end %>

              <div class="shrink-0 border-t border-zinc-200/80 p-3 bg-white [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-950">
                <form
                  id="chat-send-form"
                  phx-submit="send"
                  class="mx-auto flex max-w-[56rem] gap-2 items-end w-full"
                >
                  <div class="flex-1 relative">
                    <textarea
                      id="chat-composer"
                      name="text"
                      rows="1"
                      phx-hook="ChatComposer"
                      class="w-full min-h-[2.75rem] max-h-[12rem] resize-none rounded-2xl border border-zinc-300 bg-zinc-50 px-4 py-3 pr-12 text-[15px] leading-relaxed [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900"
                      placeholder="按 Enter 发送，Shift+Enter 换行"
                      autocomplete="off"
                    ></textarea>
                  </div>
                  <%= if @agent_busy do %>
                    <button
                      type="button"
                      phx-click="stop_agent"
                      id="chat-stop-btn"
                      class="rounded-2xl bg-red-600 p-3 text-white shadow-sm hover:bg-red-700 transition-colors shrink-0"
                      title="停止生成"
                      aria-label="停止生成"
                    >
                      <.icon name="hero-stop-circle-solid" class="size-5" />
                    </button>
                  <% else %>
                    <button
                      type="submit"
                      id="chat-send-btn"
                      class="rounded-2xl bg-emerald-600 p-3 text-white shadow-sm hover:bg-emerald-700 transition-colors shrink-0"
                      title="发送"
                      aria-label="发送"
                    >
                      <.icon name="hero-paper-airplane-solid" class="size-5" />
                    </button>
                  <% end %>
                </form>
              </div>
            <% else %>
              <%= if @project do %>
                <div class="flex flex-1 flex-col min-h-0 justify-end">
                  <div class="shrink-0 px-4 pt-6 pb-2 text-center">
                    <p class="text-sm text-zinc-600 [[data-theme=dark]_&]:text-zinc-400 max-w-lg mx-auto">
                      在下方输入首条消息将自动创建对话，标题由首句生成。侧栏可管理技能与 Memory 文档。
                    </p>
                  </div>
                  <div class="shrink-0 border-t border-zinc-200/80 p-3 bg-white [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-950">
                    <form
                      id="chat-send-form-project"
                      phx-submit="send"
                      class="mx-auto flex max-w-[56rem] gap-2 items-end w-full"
                    >
                      <div class="flex-1 relative">
                        <textarea
                          id="chat-composer-project"
                          name="text"
                          rows="1"
                          phx-hook="ChatComposer"
                          class="w-full min-h-[2.75rem] max-h-[12rem] resize-none rounded-2xl border border-zinc-300 bg-zinc-50 px-4 py-3 pr-12 text-[15px] leading-relaxed [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900"
                          placeholder="按 Enter 发送首条消息，Shift+Enter 换行"
                          autocomplete="off"
                        ></textarea>
                      </div>
                      <%= if @agent_busy do %>
                        <button
                          type="button"
                          phx-click="stop_agent"
                          id="chat-stop-btn-project"
                          class="rounded-2xl bg-red-600 p-3 text-white shadow-sm hover:bg-red-700 transition-colors shrink-0"
                          title="停止生成"
                          aria-label="停止生成"
                        >
                          <.icon name="hero-stop-circle-solid" class="size-5" />
                        </button>
                      <% else %>
                        <button
                          type="submit"
                          id="chat-send-btn-project"
                          class="rounded-2xl bg-emerald-600 p-3 text-white shadow-sm hover:bg-emerald-700 transition-colors shrink-0"
                          title="发送"
                          aria-label="发送"
                        >
                          <.icon name="hero-paper-airplane-solid" class="size-5" />
                        </button>
                      <% end %>
                    </form>
                  </div>
                </div>
              <% else %>
                <div class="flex flex-1 flex-col items-center justify-center p-8 text-center text-zinc-500">
                  <p class="text-lg font-medium text-zinc-700 [[data-theme=dark]_&]:text-zinc-300 mb-2">
                    选择项目
                  </p>
                  <p class="text-sm max-w-md">
                    请先在侧栏选择或新建项目。
                  </p>
                </div>
              <% end %>
            <% end %>
          </main>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :projects, :list, required: true
  attr :move_target, :any, required: true
  attr :current_project, :any, default: nil

  defp move_project_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[70] flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/50" phx-click="close_menu"></div>
      <div class="relative z-10 w-full max-w-sm rounded-2xl border border-zinc-200 bg-white p-4 shadow-xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
        <p class="text-sm font-medium mb-3">移动到项目</p>
        <div class="space-y-1 max-h-48 overflow-y-auto">
          <%= for p <- @projects do %>
            <%= case @move_target do %>
              <% {"session", sid} -> %>
                <button
                  type="button"
                  phx-click="move_session"
                  phx-value-id={sid}
                  phx-value-project_id={p.id}
                  class="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                >
                  {p.title}
                </button>
              <% {"skill", skid} -> %>
                <button
                  type="button"
                  phx-click="move_skill"
                  phx-value-id={skid}
                  phx-value-project_id={p.id}
                  class="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                >
                  {p.title}
                </button>
              <% _ -> %>
            <% end %>
          <% end %>
        </div>
        <button
          type="button"
          phx-click="close_menu"
          class="mt-3 w-full rounded-lg py-2 text-sm text-zinc-500"
        >
          取消
        </button>
      </div>
    </div>
    """
  end

  attr :editing, :any, required: true
  attr :projects, :list, required: true
  attr :sessions, :list, required: true

  defp edit_modal(assigns) do
    ~H"""
    <%= case @editing do %>
      <% {"project", id} -> %>
        <% p = Enum.find(@projects, &(&1.id == id)) %>
        <div class="fixed inset-0 z-[70] flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_edit"></div>
          <div class="relative z-10 w-full max-w-sm rounded-2xl border border-zinc-200 bg-white p-4 shadow-xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
            <p class="text-sm font-medium mb-2">重命名项目</p>
            <form phx-submit="rename_project" class="space-y-2">
              <input type="hidden" name="row_id" value={id} />
              <input
                type="text"
                name="title"
                value={if(p, do: p.title, else: "")}
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              />
              <div class="flex gap-2 justify-end">
                <button type="button" phx-click="cancel_edit" class="px-3 py-1.5 text-sm">取消</button>
                <button type="submit" class="rounded-lg bg-emerald-600 px-3 py-1.5 text-sm text-white">
                  保存
                </button>
              </div>
            </form>
          </div>
        </div>
      <% {"session", id} -> %>
        <% s = Enum.find(@sessions, &(&1.id == id)) %>
        <div class="fixed inset-0 z-[70] flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_edit"></div>
          <div class="relative z-10 w-full max-w-sm rounded-2xl border border-zinc-200 bg-white p-4 shadow-xl [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
            <p class="text-sm font-medium mb-2">重命名对话</p>
            <form phx-submit="rename_session" class="space-y-2">
              <input type="hidden" name="row_id" value={id} />
              <input
                type="text"
                name="title"
                value={if(s, do: s.title, else: "")}
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              />
              <div class="flex gap-2 justify-end">
                <button type="button" phx-click="cancel_edit" class="px-3 py-1.5 text-sm">取消</button>
                <button type="submit" class="rounded-lg bg-emerald-600 px-3 py-1.5 text-sm text-white">
                  保存
                </button>
              </div>
            </form>
          </div>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

  attr :form, :map, required: true
  attr :model_options, :list, default: []

  defp settings_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[70] flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/50" phx-click="toggle_settings"></div>
      <div class="relative z-10 w-full max-w-md rounded-2xl border border-zinc-200 bg-white p-5 shadow-xl max-h-[90vh] overflow-y-auto [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:bg-zinc-900">
        <h2 class="text-lg font-semibold mb-4">设置</h2>
        <form phx-submit="save_settings" id="settings-form" class="space-y-4">
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              API Base URL (openai.base_url)
            </label>
            <input
              type="text"
              name="base_url"
              value={@form["base_url"]}
              placeholder="https://api.openai.com/v1"
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              API Key（从合并后的 config 加载；留空保存则保留原密钥）
            </label>
            <input
              type="text"
              name="api_key"
              value={@form["api_key"]}
              autocomplete="off"
              placeholder="sk-…"
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm font-mono [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <div class="flex items-center justify-between gap-2 mb-1">
              <label class="block text-xs font-medium text-zinc-500">
                模型 (openai.model)
              </label>
              <button
                type="button"
                phx-click="refresh_models"
                class="text-xs font-medium text-emerald-600 hover:text-emerald-700 shrink-0"
              >
                更新模型列表
              </button>
            </div>
            <%= if @model_options != [] do %>
              <div class="mb-2">
                <label class="sr-only" for="settings-model-pick">从列表选择模型</label>
                <select
                  name="picked"
                  id="settings-model-pick"
                  phx-change="settings_pick_model"
                  class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
                >
                  <option value="">（从已拉取列表选择，或下方手动输入）</option>
                  <%= for id <- @model_options do %>
                    <option value={id} selected={id == @form["model"]}>{id}</option>
                  <% end %>
                </select>
              </div>
            <% end %>
            <input
              type="text"
              name="model"
              id="settings-model-text"
              value={@form["model"]}
              placeholder="模型 id，如 gpt-4o-mini"
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              Agent 最大轮次 (agents.max_steps：-1 不限制，0 仅对话不调用工具，≥1 为工具循环上限)
            </label>
            <input
              type="text"
              name="max_steps"
              inputmode="numeric"
              value={@form["max_steps"]}
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div class="rounded-xl border border-violet-200/80 bg-violet-50/50 p-3 space-y-3 [[data-theme=dark]_&]:border-violet-900/40 [[data-theme=dark]_&]:bg-violet-950/20">
            <p class="text-xs font-semibold text-violet-800 [[data-theme=dark]_&]:text-violet-200">
              自进化 Agent
            </p>
            <p class="text-[11px] text-zinc-600 [[data-theme=dark]_&]:text-zinc-400 leading-relaxed">
              开启后将把「带工具调用的回合」摘要写入 memory 目录下的
              <code class="font-mono text-[10px]">evolution_episodes.md</code>
              ，并在适当时机结晶技能（见下方）。不额外调用 LLM 做反思，便于本地审计与经验回放。
            </p>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input
                type="checkbox"
                name="self_evolve"
                value="true"
                checked={@form["self_evolve"] == "true"}
                class="rounded border-zinc-300"
              /> 启用自进化记录（episodes + evolution_log）
            </label>
            <label class="flex items-center gap-2 text-sm cursor-pointer">
              <input
                type="checkbox"
                name="crystallize_skills"
                value="true"
                checked={@form["crystallize_skills"] == "true"}
                class="rounded border-zinc-300"
              /> 工具回合结束后尝试结晶为技能（L3）
            </label>
            <div>
              <label class="block text-xs font-medium text-zinc-500 mb-1">
                结晶模式 (crystallize_mode)
              </label>
              <select
                name="crystallize_mode"
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              >
                <option value="auto" selected={@form["crystallize_mode"] == "auto"}>
                  auto — 自动写入技能库
                </option>
                <option value="confirm" selected={@form["crystallize_mode"] == "confirm"}>
                  confirm — 仅弹出提案，由你确认
                </option>
              </select>
            </div>
          </div>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block text-xs font-medium text-zinc-500 mb-1">temperature</label>
              <input
                type="text"
                name="temperature"
                inputmode="decimal"
                value={@form["temperature"]}
                placeholder="默认留空"
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              />
            </div>
            <div>
              <label class="block text-xs font-medium text-zinc-500 mb-1">top_p</label>
              <input
                type="text"
                name="top_p"
                inputmode="decimal"
                value={@form["top_p"]}
                placeholder="默认留空"
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              />
            </div>
            <div>
              <label class="block text-xs font-medium text-zinc-500 mb-1">top_k</label>
              <input
                type="text"
                name="top_k"
                inputmode="numeric"
                value={@form["top_k"]}
                placeholder="部分 API 忽略"
                class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
              />
            </div>
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              缓存根目录 (fluxclaw/cache，config.json 位于其下)
            </label>
            <input
              type="text"
              name="cache_root"
              value={@form["cache_root"]}
              placeholder="./fluxclaw/cache"
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">外部 Skills 目录</label>
            <input
              type="text"
              name="external_skills"
              value={@form["external_skills"]}
              placeholder=".cursor/skills 或自定义路径"
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              内部 Skills 目录（默认可为 缓存根/skills）
            </label>
            <input
              type="text"
              name="internal_skills"
              value={@form["internal_skills"]}
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              对话 / History 目录（默认可为 缓存根/history）
            </label>
            <input
              type="text"
              name="history_root"
              value={@form["history_root"]}
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 mb-1">
              Memory 目录（默认可为 缓存根/memory）
            </label>
            <input
              type="text"
              name="memory_root"
              value={@form["memory_root"]}
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-600 [[data-theme=dark]_&]:bg-zinc-800"
            />
          </div>
          <div class="flex gap-2 justify-end pt-2">
            <button type="button" phx-click="toggle_settings" class="px-3 py-2 text-sm rounded-lg">
              关闭
            </button>
            <button
              type="submit"
              class="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
            >
              保存
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :items, :list, required: true

  def tools_flow_block(assigns) do
    assigns = assign(assigns, :count, length(assigns.items))

    ~H"""
    <details class="group rounded-xl border border-zinc-200 bg-zinc-50/80 [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/40">
      <summary class="cursor-pointer select-none list-none flex items-center gap-2 px-3 py-2.5 text-xs font-medium text-zinc-600 [[data-theme=dark]_&]:text-zinc-400 [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 transition-transform group-open:rotate-90"
        /> 工具与流程（{@count} 条）· 点击展开
      </summary>
      <div class="space-y-2 border-t border-zinc-200/80 px-2 py-3 [[data-theme=dark]_&]:border-zinc-800">
        <%= for i <- @items do %>
          <.chat_bubble entry={i} />
        <% end %>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  def task_plan_tool_result(assigns) do
    {title, steps} = parse_task_plan(assigns.text)
    assigns = assigns |> assign(:plan_title, title) |> assign(:plan_steps, steps)

    ~H"""
    <div class="flex justify-center w-full">
      <div class="w-full max-w-[min(40rem,95%)] rounded-xl border border-indigo-200/90 bg-indigo-50/90 px-4 py-3 [[data-theme=dark]_&]:border-indigo-900/50 [[data-theme=dark]_&]:bg-indigo-950/30">
        <div class="flex items-center gap-2 text-xs font-medium text-indigo-800 [[data-theme=dark]_&]:text-indigo-200">
          <.icon name="hero-clipboard-document-list" class="size-4 shrink-0" /> 任务计划
          <span class="text-zinc-400 font-mono font-normal">{@id}</span>
        </div>
        <%= if @plan_title do %>
          <p class="mt-2 text-sm font-semibold text-zinc-800 [[data-theme=dark]_&]:text-zinc-100">
            {@plan_title}
          </p>
        <% end %>
        <%= if @plan_steps != [] do %>
          <ol class="mt-2 list-decimal list-inside space-y-1 text-sm text-zinc-700 [[data-theme=dark]_&]:text-zinc-300">
            <%= for s <- @plan_steps do %>
              <li class="pl-0.5">{s}</li>
            <% end %>
          </ol>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  def web_fetch_tool_result(assigns) do
    url = first_url_in_text(assigns.text)
    host = if(url, do: uri_display_host(url), else: "链接")
    preview = String.slice(assigns.text || "", 0, 320)
    assigns = assigns |> assign(:url, url) |> assign(:host, host) |> assign(:preview, preview)

    ~H"""
    <div class="flex justify-center w-full">
      <div class="w-full max-w-[min(40rem,95%)] rounded-xl border border-sky-200/90 bg-sky-50/80 px-4 py-3 [[data-theme=dark]_&]:border-sky-900/50 [[data-theme=dark]_&]:bg-sky-950/25">
        <p class="text-[11px] font-medium uppercase tracking-wide text-sky-800/80 [[data-theme=dark]_&]:text-sky-200/90">
          网页摘录
        </p>
        <%= if @url do %>
          <a
            href={@url}
            class="mt-1 inline-flex items-center gap-1 text-sm font-semibold text-sky-600 hover:text-sky-700 underline underline-offset-2 [[data-theme=dark]_&]:text-sky-400"
          >
            {@host}
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5 opacity-70" />
          </a>
        <% else %>
          <p class="mt-1 text-sm text-zinc-500">（未解析到 URL，见下方全文）</p>
        <% end %>
        <p class="mt-2 text-xs text-zinc-600 line-clamp-4 [[data-theme=dark]_&]:text-zinc-400 whitespace-pre-wrap">
          {@preview}
        </p>
        <details class="mt-2 group">
          <summary class="cursor-pointer text-[11px] text-zinc-400 hover:text-zinc-600">
            显示完整抓取文本
          </summary>
          <pre class="mt-1 max-h-48 overflow-y-auto whitespace-pre-wrap text-[11px] text-zinc-500 border-t border-zinc-200/80 pt-2 [[data-theme=dark]_&]:border-zinc-700">{@text}</pre>
        </details>
      </div>
    </div>
    """
  end

  defp parse_task_plan(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    numbered = Enum.filter(lines, &Regex.match?(~r/^\d+[\.\)]\s*\S/u, &1))
    title_candidate = Enum.find(lines, fn l -> l not in numbered end)

    steps =
      Enum.map(numbered, fn s -> String.replace(s, ~r/^\d+[\.\)]\s*/, "") end)

    cond do
      steps != [] and title_candidate ->
        {title_candidate, steps}

      steps != [] ->
        {nil, steps}

      true ->
        {List.first(lines), Enum.drop(lines, 1)}
    end
  end

  defp parse_task_plan(_), do: {nil, []}

  defp first_url_in_text(text) when is_binary(text) do
    case Regex.run(~r/https?:\/\/[^\s\)\]\>\"']+/, text) do
      [u] ->
        u
        |> String.trim_trailing(")")
        |> String.trim_trailing("],")
        |> String.trim_trailing(".")

      _ ->
        nil
    end
  end

  defp first_url_in_text(_), do: nil

  defp uri_display_host(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> url
    end
  end

  attr :entry, :any, required: true

  def chat_bubble(assigns) do
    ~H"""
    <%= case @entry do %>
      <% {:history, "user", content} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:history, "assistant", content} -> %>
        <.bubble_assistant content={message_content_string(content)} />
      <% {:history, role, content} -> %>
        <.bubble_system role={to_string(role || "")} content={message_content_string(content)} />
      <% {:user, content} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:assistant, content} -> %>
        <.bubble_assistant content={message_content_string(content)} />
      <% {:reasoning, content} -> %>
        <details class="group rounded-xl border border-violet-200/80 bg-violet-50/80 [[data-theme=dark]_&]:border-violet-900/40 [[data-theme=dark]_&]:bg-violet-950/25">
          <summary class="cursor-pointer select-none list-none flex items-center gap-2 px-4 py-2.5 text-xs font-medium text-violet-700 [[data-theme=dark]_&]:text-violet-300 [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-4 shrink-0 transition-transform group-open:rotate-90"
            />
            <.icon name="hero-sparkles" class="size-4" /> 思考过程 · 点击展开
          </summary>
          <div class="chat-md border-t border-violet-200/60 px-4 py-3 text-sm [[data-theme=dark]_&]:border-violet-900/40">
            {raw(md_html(message_content_string(content)))}
          </div>
        </details>
      <% {:tool_start, name, args} -> %>
        <div class="flex justify-center">
          <div class="rounded-xl border border-zinc-200 bg-zinc-50/90 px-3 py-2 text-xs text-zinc-600 max-w-[min(40rem,95%)] [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/50 [[data-theme=dark]_&]:text-zinc-400">
            <span class="font-mono text-emerald-600 [[data-theme=dark]_&]:text-emerald-400">工具</span> {to_string(
              name || ""
            )}
            <pre class="mt-1 overflow-x-auto text-[11px]">{inspect(args, pretty: true)}</pre>
          </div>
        </div>
      <% {:tool_done, id, name, text} -> %>
        <%= cond do %>
          <% name == "task_plan" -> %>
            <.task_plan_tool_result id={to_string(id || "")} text={message_content_string(text)} />
          <% name == "web_fetch" -> %>
            <.web_fetch_tool_result id={to_string(id || "")} text={message_content_string(text)} />
          <% true -> %>
            <div class="flex justify-center">
              <div class="rounded-xl border border-dashed border-zinc-200 bg-zinc-50/50 px-3 py-2 text-xs max-w-[min(40rem,95%)] [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/40">
                <span class="text-zinc-400">结果</span> <span class="font-mono">{to_string(name || "")}</span>{" "}<span class="font-mono">{to_string(id || "")}</span>
                <pre class="mt-1 whitespace-pre-wrap text-[11px] text-zinc-600 [[data-theme=dark]_&]:text-zinc-400">{message_content_string(text)}</pre>
              </div>
            </div>
        <% end %>
      <% other -> %>
        <div class="flex justify-center">
          <pre class="max-w-[min(40rem,95%)] whitespace-pre-wrap rounded-lg border border-amber-200 bg-amber-50/80 px-3 py-2 text-xs text-amber-900 [[data-theme=dark]_&]:border-amber-900/50 [[data-theme=dark]_&]:bg-amber-950/30 [[data-theme=dark]_&]:text-amber-100">{inspect(other, pretty: true)}</pre>
        </div>
    <% end %>
    """
  end

  attr :content, :string, required: true

  def bubble_user(assigns) do
    ~H"""
    <div class="flex justify-end gap-2.5 items-end">
      <div class="max-w-[min(40rem,85%)] rounded-2xl rounded-br-md bg-emerald-600 text-white px-4 py-2.5 text-[15px] leading-relaxed shadow-sm">
        <div class="whitespace-pre-wrap">{@content}</div>
      </div>
      <img
        src={~p"/images/fluxclaw-user.png"}
        alt=""
        width="32"
        height="32"
        class="size-8 rounded-full shrink-0 object-cover ring-2 ring-white shadow-sm mb-0.5 [[data-theme=dark]_&]:ring-zinc-800"
      />
    </div>
    """
  end

  attr :content, :string, required: true

  def bubble_assistant(assigns) do
    html = md_html(assigns.content)
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="flex justify-start gap-2.5 items-start">
      <img
        src={~p"/images/fluxclaw-assistant.png"}
        alt=""
        width="32"
        height="32"
        class="size-8 rounded-full shrink-0 object-cover ring-2 ring-emerald-100 shadow-sm mt-1 [[data-theme=dark]_&]:ring-emerald-900/50"
      />
      <div class="chat-md min-w-0 flex-1 max-w-[min(48rem,100%)] rounded-2xl rounded-bl-md border border-zinc-200 bg-zinc-50 px-4 py-3 text-[15px] leading-relaxed [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/60">
        {raw(@html)}
      </div>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  def bubble_system(assigns) do
    html = md_html(assigns.content)
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="flex justify-start">
      <div class="chat-md max-w-[min(48rem,92%)] rounded-xl border border-zinc-100 bg-zinc-100/60 px-3 py-2 text-sm [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900/40">
        <span class="text-xs text-zinc-400">{@role}</span>
        <div>{raw(@html)}</div>
      </div>
    </div>
    """
  end
end
