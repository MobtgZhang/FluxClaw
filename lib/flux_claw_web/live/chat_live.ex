defmodule FluxClawWeb.ChatLive do
  use FluxClawWeb, :live_view

  require Logger

  alias FluxClaw.Agents
  alias FluxClaw.Agents.AgentMessage
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
    |> assign(:sidebar_collapsed, false)
    |> assign(:right_open, false)
    |> assign(:right_tab, :memory)
    |> assign(:pending_diff, nil)
    |> assign(:plugins_info, plugins_summary())
    |> assign(:chat_subscribed_topic, nil)
    |> assign(:user_variant_idx, %{})
    |> assign(:user_edit_meta, %{})
    |> assign(:editing_user_msg, nil)
    |> assign(:composer_form, to_form(%{"text" => ""}))
    |> assign(:answer_form, to_form(%{"text" => ""}))
    |> assign(:attachment_form, to_form(%{}, as: :attachment))
    |> assign(:run_status, nil)
    |> assign(:integration_form, integration_form())
    |> allow_upload(:attachments, accept: :any, max_entries: 5, max_file_size: 8_000_000)
    |> stream(:artifacts, [])
    |> stream(:turns, [])
  end

  defp wire_pubsub_after_static_render(socket) do
    if connected?(socket) && socket.assigns[:plugins_subscribed] != true do
      Phoenix.PubSub.subscribe(FluxClaw.PubSub, "flux_claw:plugins")
      socket = assign(socket, :plugins_subscribed, true)

      socket
      |> subscribe_session(socket.assigns.session.id)
      |> assign(:agent_busy, composer_agent_busy?(socket.assigns.session.id))
    else
      socket
    end
  end

  defp integration_form do
    cfg = FluxClaw.Integrations.config()

    to_form(
      %{
        "search_url" => cfg.search_url,
        "search_mode" => cfg.search_mode,
        "search_key" => "",
        "python" => cfg.python
      },
      as: :integrations
    )
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
  def handle_params(params, uri, socket) do
    {:noreply, next} = dispatch_params(params, uri, socket)
    {:noreply, sync_turns(next)}
  end

  defp dispatch_params(params, _uri, socket) do
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
    |> assign(:pending_diff, nil)
    |> assign(:user_variant_idx, %{})
    |> assign(:user_edit_meta, %{})
    |> assign(:editing_user_msg, nil)
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
        |> assign(:pending_diff, nil)
        |> assign(:user_variant_idx, %{})
        |> assign(:user_edit_meta, %{})
        |> assign(:editing_user_msg, nil)
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

        msgs = Agents.list_messages(session.id)
        log = history_entries(msgs)
        user_meta = build_user_edit_meta(msgs)
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
        |> assign(:user_edit_meta, user_meta)
        |> assign(:user_variant_idx, %{})
        |> assign(:editing_user_msg, nil)
        |> assign(:draft_assistant, nil)
        |> assign(:draft_reasoning, nil)
        |> assign(:pending_ask, nil)
        |> assign(:pending_diff, nil)
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

            case Map.get(m.metadata, "call_id") do
              nil -> [{:tool_start, n, args}]
              id -> [{:tool_start, id, n, args}]
            end

          "done" ->
            id = meta_call_id(m.metadata)
            n = m.tool_name || "tool"
            [{:tool_done, id, n, message_content_string(m.content)}]

          _ ->
            []
        end

      "user" ->
        [{:history, "user", message_content_string(m.content), m.id}]

      "assistant" ->
        tc = meta_tool_calls_list(m.metadata)
        c = message_content_string(m.content)

        cond do
          Map.get(m.metadata || %{}, "stopped") == true ->
            answer = if c != "", do: [{:history, "assistant", c, m.id}], else: []
            answer ++ [{:stopped, m.id}]

          tc != [] and c != "" ->
            [{:history, "assistant", c, m.id}]

          tc != [] ->
            []

          true ->
            if c != "", do: [{:history, "assistant", c, m.id}], else: []
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

  defp meta_call_id(meta) when is_map(meta) do
    Map.get(meta, "call_id") || Map.get(meta, :call_id) || "call"
  end

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
  def handle_event(event, params, socket) do
    case dispatch_event(event, params, socket) do
      {:noreply, next} -> {:noreply, sync_turns(next)}
      {:reply, reply, next} -> {:reply, reply, sync_turns(next)}
    end
  end

  @impl true
  def handle_info(message, socket) do
    {:noreply, next} = dispatch_info(message, socket)
    {:noreply, sync_turns(next)}
  end

  defp sync_turns(socket) do
    source =
      {socket.assigns.log, socket.assigns.user_edit_meta, socket.assigns.user_variant_idx,
       socket.assigns.editing_user_msg}

    sid = socket.assigns.session && socket.assigns.session.id

    socket =
      if socket.assigns[:artifact_session] != sid do
        socket |> assign(:artifact_session, sid) |> stream(:artifacts, [], reset: true)
      else
        socket
      end

    if socket.assigns[:turn_source] == source do
      socket
    else
      turns =
        chat_slices(
          socket.assigns.log,
          socket.assigns.user_edit_meta,
          socket.assigns.user_variant_idx
        )
        |> Enum.with_index()
        |> Enum.map(fn {slice, index} ->
          id =
            case slice do
              {:user_turn, id, _, _, _, _} when not is_nil(id) -> "user-#{id}"
              _ -> "plain-#{index}"
            end

          %{id: id, slice: slice}
        end)

      socket |> assign(:turn_source, source) |> stream(:turns, turns, reset: true)
    end
  end

  defp dispatch_event("save_integrations", %{"integrations" => params}, socket) do
    url = String.trim(params["search_url"] || "")
    mode = params["search_mode"] || "local"
    uri = URI.parse(url)

    if mode in ["local", "sciphi"] and
         (url == "" or (uri.scheme in ["http", "https"] and uri.host not in [nil, ""])) do
      updates = Map.take(params, ["search_url", "search_mode", "python"])

      updates =
        if String.trim(params["search_key"] || "") == "",
          do: updates,
          else: Map.put(updates, "search_key", params["search_key"])

      FluxClaw.ConfigLoader.merge_save!(%{"integrations" => updates})

      {:noreply,
       socket
       |> assign(:integration_form, integration_form())
       |> put_flash(:info, "工具配置已保存；服务连通性将在实际调用时验证。")}
    else
      {:noreply, put_flash(socket, :error, "请填写有效的 http(s) 服务地址。")}
    end
  end

  defp dispatch_event("refresh_artifacts", _, socket) do
    files =
      if socket.assigns.session, do: FluxClaw.Artifacts.list(socket.assigns.session.id), else: []

    {:noreply, stream(socket, :artifacts, files, reset: true)}
  end

  defp dispatch_event("validate_upload", _, socket), do: {:noreply, socket}

  defp dispatch_event("upload_files", _, socket) do
    if socket.assigns.session do
      root = FluxClaw.Artifacts.root(socket.assigns.session.id)

      paths =
        consume_uploaded_entries(socket, :attachments, fn %{path: source}, entry ->
          relative = "uploads/" <> Ecto.UUID.generate() <> "-" <> Path.basename(entry.client_name)

          with {:ok, destination} <- FluxClaw.Tools.Sandbox.resolve!(root, relative),
               :ok <- File.mkdir_p(Path.dirname(destination)),
               :ok <- File.cp(source, destination) do
            {:ok, relative}
          else
            _ -> {:postpone, :retry}
          end
        end)

      socket =
        socket
        |> stream(:artifacts, FluxClaw.Artifacts.list(socket.assigns.session.id), reset: true)
        |> push_event("composer-attach", %{paths: paths})

      {:noreply, put_flash(socket, :info, "附件已保存到当前任务；可在输入框中说明处理方式。")}
    else
      {:noreply, put_flash(socket, :error, "请先发送任务以创建会话，再添加附件。")}
    end
  end

  defp dispatch_event("fill_example", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "composer-fill", %{text: text})}
  end

  defp dispatch_event("close_drawers", _, socket) do
    {:noreply,
     socket
     |> assign(:sidebar_open, false)
     |> assign(:right_open, false)
     |> assign(:context_menu, nil)
     |> assign(:menu_anchor, nil)}
  end

  defp dispatch_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open, &(!&1))}
  end

  defp dispatch_event("toggle_settings", _params, socket) do
    open = !socket.assigns.settings_open

    socket =
      if open do
        assign(socket, :settings_form, settings_form_defaults())
      else
        socket
      end

    {:noreply, assign(socket, :settings_open, open)}
  end

  defp dispatch_event("close_menu", _params, socket) do
    {:noreply,
     assign(socket,
       menu: nil,
       move_target: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  defp dispatch_event("open_context_menu", params, socket) do
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

  defp dispatch_event("toggle_nav", %{"section" => section}, socket) do
    nav = socket.assigns.nav_open

    if Map.has_key?(nav, section) do
      cur = Map.fetch!(nav, section)
      {:noreply, assign(socket, :nav_open, Map.put(nav, section, !cur))}
    else
      {:noreply, socket}
    end
  end

  defp dispatch_event("toggle_menu", %{"type" => type, "id" => id}, socket) do
    cur = socket.assigns.menu

    menu =
      if cur == {type, id} do
        nil
      else
        {type, id}
      end

    {:noreply, assign(socket, menu: menu, move_target: nil)}
  end

  defp dispatch_event("open_move", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       move_target: {type, id},
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  defp dispatch_event("new_project", %{"title" => title}, socket) do
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

  defp dispatch_event("new_project", _params, socket) do
    case Projects.create_project(%{title: "新项目"}) do
      {:ok, p} -> {:noreply, push_patch(socket, to: ~p"/p/#{p.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "创建失败")}
    end
  end

  defp dispatch_event("new_chat", %{"title" => title}, socket) do
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

  defp dispatch_event("new_chat", _params, socket) do
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

  defp dispatch_event("delete_session", %{"id" => id}, socket) do
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

  defp dispatch_event("delete_skill", %{"id" => id}, socket) do
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

  defp dispatch_event("delete_project", %{"id" => id}, socket) do
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

  defp dispatch_event("rename_project", %{"row_id" => id, "title" => title}, socket) do
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

  defp dispatch_event("rename_session", %{"row_id" => id, "title" => title}, socket) do
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

  defp dispatch_event("start_edit", %{"kind" => kind, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       editing: {kind, id},
       menu: nil,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  defp dispatch_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  defp dispatch_event("move_session", %{"id" => sid, "project_id" => pid}, socket) do
    case Agents.get_session(sid) do
      nil ->
        {:noreply, put_flash(socket, :error, "会话不存在")}

      s ->
        {:ok, _} = Agents.move_session_to_project(s, pid)
        {:noreply, socket |> assign(:move_target, nil) |> push_patch(to: ~p"/p/#{pid}")}
    end
  end

  defp dispatch_event("move_skill", %{"id" => skill_id, "project_id" => pid}, socket) do
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

  defp dispatch_event("open_skill_editor", %{"id" => id}, socket) do
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

  defp dispatch_event("open_skill_editor_new", _params, socket) do
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

  defp dispatch_event("open_skill_import", _params, socket) do
    files = Memory.list_skill_import_files()

    {:noreply,
     assign(socket,
       skill_import_open: true,
       skill_import_files: files,
       context_menu: nil,
       menu_anchor: nil
     )}
  end

  defp dispatch_event("close_skill_import", _params, socket) do
    {:noreply, assign(socket, :skill_import_open, false)}
  end

  defp dispatch_event("import_skill_pick", %{"path" => path}, socket) do
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

  defp dispatch_event("close_skill_editor", _params, socket) do
    {:noreply, assign(socket, :skill_editor, nil)}
  end

  defp dispatch_event("save_skill_editor", params, socket) do
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

  defp dispatch_event("external_link_click", %{"url" => url, "title" => title}, socket) do
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

  defp dispatch_event("cancel_external_link", _params, socket) do
    {:noreply, assign(socket, :external_link_prompt, nil)}
  end

  defp dispatch_event("confirm_external_link", _params, socket) do
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

  defp dispatch_event("settings_pick_model", %{"picked" => picked}, socket) do
    picked = String.trim(picked || "")
    form = Map.put(socket.assigns.settings_form, "model", picked)
    {:noreply, assign(socket, :settings_form, form)}
  end

  defp dispatch_event("settings_pick_model", _params, socket) do
    {:noreply, socket}
  end

  defp dispatch_event("refresh_models", _params, socket) do
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

  defp dispatch_event("save_settings", params, socket) do
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

  defp dispatch_event("accept_skill_proposal", _params, socket) do
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

  defp dispatch_event("dismiss_skill_proposal", _params, socket) do
    {:noreply, assign(socket, :skill_proposal, nil)}
  end

  defp dispatch_event("stop_agent", _params, socket) do
    case socket.assigns.session do
      %{id: sid} ->
        stop_session_worker(sid)
        partial = socket.assigns.draft_assistant || ""
        {:ok, _} = Agents.record_stop(sid, partial)

        {:noreply,
         socket
         |> reload_chat_from_db()
         |> assign(:run_status, "已停止 · 已完成的操作和部分回答已保留")
         |> assign(:pending_ask, nil)
         |> assign(:pending_diff, nil)
         |> assign(:agent_busy, false)
         |> assign(:draft_assistant, nil)
         |> assign(:draft_reasoning, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  defp dispatch_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.agent_busy || socket.assigns.pending_ask != nil ||
          socket.assigns.pending_diff != nil ->
        {:noreply, put_flash(socket, :info, "请先停止当前任务或回复待处理的问题")}

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

                    {:noreply,
                     socket
                     |> push_event("composer-clear", %{})
                     |> push_patch(to: ~p"/chat/#{s.id}")}

                  {:error, _} ->
                    {:noreply, put_flash(socket, :error, "发送失败")}
                end

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "创建对话失败")}
            end
        end

      true ->
        Orchestrator.send_message(socket.assigns.session.id, text)

        {:noreply,
         socket
         |> assign(:agent_busy, true)
         |> assign(:run_status, nil)
         |> push_event("composer-clear", %{})}
    end
  end

  defp dispatch_event("answer_user", %{"ref" => ref_str, "text" => text}, socket) do
    with {ref, ""} <- Integer.parse(ref_str),
         %{ref: ^ref} <- socket.assigns.pending_ask,
         %{id: sid} <- socket.assigns.session,
         answer when answer != "" <- String.trim(text) do
      Orchestrator.reply_ask_user(sid, ref, answer)
      {:noreply, socket |> assign(:agent_busy, true) |> assign(:pending_ask, nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp dispatch_event("toggle_sidebar_rail", _params, socket) do
    {:noreply, update(socket, :sidebar_collapsed, &(!&1))}
  end

  defp dispatch_event("toggle_right", _params, socket) do
    {:noreply, update(socket, :right_open, &(!&1))}
  end

  defp dispatch_event("set_right_tab", %{"tab" => tab}, socket) do
    tab =
      case tab do
        "timeline" -> :timeline
        "memory" -> :memory
        "files" -> :files
        "plugins" -> :plugins
        _ -> :plugins
      end

    {:noreply, socket |> assign(:right_tab, tab) |> assign(:right_open, true)}
  end

  defp dispatch_event("review_diff", %{"ref" => ref_str, "decision" => decision}, socket) do
    ref = String.to_integer(ref_str)
    decision = if decision in ["keep", "accept", "apply", "true"], do: "keep", else: "reject"

    socket =
      case socket.assigns.session do
        %{id: sid} ->
          Orchestrator.reply_diff_review(sid, ref, decision)
          assign(socket, :agent_busy, true)

        _ ->
          socket
      end

    {:noreply, assign(socket, :pending_diff, nil)}
  end

  defp dispatch_event("refresh_plugins", _params, socket) do
    {:noreply, refresh_plugins_info(socket)}
  end

  defp dispatch_event("copy_assistant_text", %{"id" => id_str}, socket) do
    text = assistant_plaintext_from_db(socket, id_str) || ""
    {:noreply, push_event(socket, "clipboard-copy", %{text: text})}
  end

  defp dispatch_event("export_assistant_md", %{"id" => id_str}, socket) do
    text = assistant_plaintext_from_db(socket, id_str) || ""
    slug = id_str |> String.trim() |> String.replace("-", "") |> String.slice(0, 8)
    name = "fluxclaw-reply-#{slug}.md"

    {:noreply,
     push_event(socket, "download-text", %{
       filename: name,
       text: text,
       mime: "text/markdown;charset=utf-8"
     })}
  end

  defp dispatch_event("regenerate_assistant", %{"id" => id_str}, socket) do
    id_str = String.trim(id_str)

    with %{session: %{id: sid}} <- socket.assigns,
         {:ok, uuid} <- Ecto.UUID.cast(id_str),
         :ok <- Agents.regenerate_from_assistant_message(sid, uuid) do
      stop_session_worker(sid)
      _ = Orchestrator.ensure_worker(sid)

      socket =
        socket
        |> assign(:editing_user_msg, nil)
        |> assign(:draft_assistant, nil)
        |> assign(:draft_reasoning, nil)
        |> reload_chat_from_db()
        |> assign(:agent_busy, true)

      {:noreply, socket}
    else
      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "无法重新生成该条回复")}

      _ ->
        {:noreply, put_flash(socket, :error, "无法重新生成该条回复")}
    end
  end

  defp dispatch_event("copy_user_text", %{"id" => id_str}, socket) do
    id_str = String.trim(id_str)

    text =
      chat_slices(
        socket.assigns.log,
        socket.assigns.user_edit_meta,
        socket.assigns.user_variant_idx
      )
      |> Enum.find_value(fn
        {:user_turn, ^id_str, t, _, _, _} -> t
        _ -> nil
      end)

    {:noreply, push_event(socket, "clipboard-copy", %{text: text || ""})}
  end

  defp dispatch_event("start_edit_user", %{"id" => id_str}, socket) do
    id_str = String.trim(id_str)

    txt =
      chat_slices(
        socket.assigns.log,
        socket.assigns.user_edit_meta,
        socket.assigns.user_variant_idx
      )
      |> Enum.find_value(fn
        {:user_turn, kid, t, _, _, _} when kid == id_str -> t
        _ -> nil
      end)

    case txt do
      t when is_binary(t) ->
        case Map.get(socket.assigns.user_edit_meta, id_str) do
          %{versions: vsn} ->
            last_i = length(vsn) - 1
            cur = Map.get(socket.assigns.user_variant_idx, id_str, last_i)

            if cur != last_i do
              {:noreply, put_flash(socket, :error, "请用「>」切换到最新版本后再修改")}
            else
              {:noreply, assign(socket, :editing_user_msg, %{id: id_str, draft: t})}
            end

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp dispatch_event("cancel_edit_user", _, socket) do
    {:noreply, assign(socket, :editing_user_msg, nil)}
  end

  defp dispatch_event("user_variant_step", %{"id" => id_str, "dir" => dir_s}, socket) do
    dir = String.to_integer(dir_s)
    id_str = String.trim(id_str)

    case Map.get(socket.assigns.user_edit_meta, id_str) do
      %{versions: vsn} ->
        max_i = length(vsn) - 1
        cur = Map.get(socket.assigns.user_variant_idx, id_str, max_i)
        next = min(max_i, max(0, cur + dir))

        {:noreply,
         assign(socket, :user_variant_idx, Map.put(socket.assigns.user_variant_idx, id_str, next))}

      _ ->
        {:noreply, socket}
    end
  end

  defp dispatch_event("submit_user_edit", %{"user_message_id" => id_str, "text" => text}, socket) do
    text = String.trim(text)
    id_str = String.trim(id_str)

    with %{session: %{id: sid}} <- socket.assigns,
         false <- text == "",
         {:ok, uuid} <- Ecto.UUID.cast(id_str),
         %AgentMessage{} = msg <- Agents.get_message(uuid),
         true <- to_string(msg.session_id) == to_string(sid),
         "user" <- msg.role do
      meta = msg.metadata || %{}

      versions =
        case meta do
          %{"edit_versions" => vs} when is_list(vs) and vs != [] -> vs
          _ -> [message_content_string(msg.content)]
        end

      snapshots =
        case meta do
          %{"edit_snapshots" => ss} when is_list(ss) -> ss
          _ -> []
        end

      last_i = length(versions) - 1
      cur = Map.get(socket.assigns.user_variant_idx, id_str, last_i)

      if cur != last_i do
        {:noreply, put_flash(socket, :error, "请切换到最新版本后再发送")}
      else
        tail = db_tail_log_entries(sid, msg.id)
        enc = encode_snapshot(tail)
        new_snapshots = snapshots ++ [enc]
        new_versions = versions ++ [text]

        new_meta =
          meta
          |> Map.put("edit_versions", new_versions)
          |> Map.put("edit_snapshots", new_snapshots)

        case Agents.update_message(msg, %{content: text, metadata: new_meta}) do
          {:ok, _} ->
            _ = Agents.delete_messages_after(msg)
            stop_session_worker(sid)
            _ = Orchestrator.ensure_worker(sid)

            socket =
              socket
              |> assign(:editing_user_msg, nil)
              |> reload_chat_from_db()

            nv = Map.fetch!(socket.assigns.user_edit_meta, id_str).versions
            idx = length(nv) - 1

            vidx = Map.put(socket.assigns.user_variant_idx, id_str, idx)

            {:noreply, assign(socket, :user_variant_idx, vidx)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "保存失败")}
        end
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "无法保存修改")}
    end
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

  defp refresh_plugins_info(socket) do
    assign(socket, :plugins_info, plugins_summary())
  end

  defp plugins_summary do
    FluxClaw.Plugins.summary()
  rescue
    e -> %{error: Exception.message(e)}
  end

  defp diff_lines(diff) when is_binary(diff) do
    FluxClaw.Tools.Diff.diff_lines(diff)
  end

  defp diff_lines(_), do: []

  defp dispatch_info({:user, text, id}, socket) do
    id_key = to_string(id)

    meta =
      if Map.has_key?(socket.assigns.user_edit_meta, id_key) do
        socket.assigns.user_edit_meta
      else
        Map.put(socket.assigns.user_edit_meta, id_key, %{versions: [text], snapshots: []})
      end

    {:noreply,
     socket
     |> assign(:user_edit_meta, meta)
     |> assign(:log, socket.assigns.log ++ [{:user, text, id}])}
  end

  defp dispatch_info({:user, text}, socket) do
    {:noreply, assign(socket, :log, socket.assigns.log ++ [{:user, text, nil}])}
  end

  defp dispatch_info({:session_title_updated, title}, socket) do
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

  defp dispatch_info({:reasoning_delta, text}, socket) do
    cur = socket.assigns.draft_reasoning || ""
    {:noreply, assign(socket, :draft_reasoning, cur <> text)}
  end

  defp dispatch_info({:reasoning_done, text}, socket) do
    socket =
      socket
      |> assign(:draft_reasoning, nil)
      |> push_log({:reasoning, text})

    {:noreply, socket}
  end

  defp dispatch_info({:assistant_delta, text}, socket) do
    cur = socket.assigns.draft_assistant || ""
    {:noreply, assign(socket, :draft_assistant, cur <> text)}
  end

  defp dispatch_info({:assistant_done, text, msg_id}, socket) do
    entry =
      case msg_id do
        nil -> {:assistant, text}
        id -> {:assistant, text, id}
      end

    log = socket.assigns.log ++ [entry]

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

  defp dispatch_info({:assistant_done, text}, socket) do
    dispatch_info({:assistant_done, text, nil}, socket)
  end

  defp dispatch_info({:tool_start, id, name, args}, socket) do
    {:noreply, socket |> push_log({:tool_start, id, name, args}) |> assign(:agent_busy, true)}
  end

  defp dispatch_info({:tool_start, name, args}, socket) do
    {:noreply, socket |> push_log({:tool_start, name, args}) |> assign(:agent_busy, true)}
  end

  defp dispatch_info({:tool_done, id, name, text}, socket) do
    {:noreply, socket |> push_log({:tool_done, id, name, text}) |> assign(:agent_busy, true)}
  end

  defp dispatch_info({:ask_user, ref, question}, socket) do
    {:noreply,
     socket
     |> assign(:pending_ask, %{ref: ref, question: question})
     |> assign(:agent_busy, false)}
  end

  defp dispatch_info({:skill_proposal, attrs}, socket) do
    {:noreply, assign(socket, :skill_proposal, attrs)}
  end

  defp dispatch_info({:skill_saved, _title}, socket) do
    sk =
      if p = socket.assigns.project do
        Memory.list_skills_for_project(p.id)
      else
        Memory.list_skills_recent(32)
      end

    {:noreply, assign(socket, :skills_sidebar, sk)}
  end

  defp dispatch_info({:error, reason}, socket) do
    {:noreply,
     socket
     |> assign(:run_status, "模型请求失败：" <> short_error_body(reason))
     |> assign(:agent_busy, false)}
  end

  defp dispatch_info({:diff_proposed, ref, payload}, socket) do
    pending = Map.put(Map.new(payload || %{}), "ref", ref)

    {:noreply,
     socket
     |> assign(:pending_diff, pending)
     |> assign(:agent_busy, false)}
  end

  defp dispatch_info({:diff_reviewed, _ref, _decision}, socket) do
    socket = sync_agent_busy_from_db(socket)

    {:noreply, assign(socket, :pending_diff, nil)}
  end

  defp dispatch_info({:plugin_loaded, _id}, socket) do
    {:noreply, refresh_plugins_info(socket)}
  end

  defp dispatch_info({:plugin_tool_registered, _plugin_id, _name}, socket) do
    {:noreply, refresh_plugins_info(socket)}
  end

  defp dispatch_info({:plugin_tool_unregistered, _name}, socket) do
    {:noreply, refresh_plugins_info(socket)}
  end

  defp dispatch_info(_other, socket), do: {:noreply, socket}

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
    {entries, tools} =
      Enum.reduce(log, {[], []}, fn entry, {entries, tools} ->
        case entry do
          {:tool_start, _, _, _} -> {entries, [entry | tools]}
          {:tool_start, _, _} -> {entries, [entry | tools]}
          {:tool_done, _, _, _} -> {entries, [entry | tools]}
          _ -> {[entry | entries], tools}
        end
      end)

    # One activity group per user turn, including calls separated by assistant text.
    # Answers stay first so completed deliverables are immediately readable.
    Enum.reverse(entries) ++ if(tools == [], do: [], else: [{:tools, Enum.reverse(tools)}])
  end

  defp build_user_edit_meta(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(&1.role == "user"))
    |> Map.new(fn m ->
      id = to_string(m.id)
      meta = m.metadata || %{}

      versions =
        case meta do
          %{"edit_versions" => vs} when is_list(vs) and vs != [] ->
            vs

          _ ->
            [message_content_string(m.content)]
        end

      snapshots =
        case meta do
          %{"edit_snapshots" => ss} when is_list(ss) -> ss
          _ -> []
        end

      {id, %{versions: versions, snapshots: snapshots}}
    end)
  end

  defp user_anchor?({:history, "user", _, _}), do: true
  defp user_anchor?({:user, _, _}), do: true
  defp user_anchor?({:user, _}), do: true
  defp user_anchor?(_), do: false

  defp split_log_by_user_anchors(log) do
    {prefix, rest} = Enum.split_while(log, &(not user_anchor?(&1)))
    {prefix, split_user_pairs(rest, [])}
  end

  defp split_user_pairs([], acc), do: Enum.reverse(acc)

  defp split_user_pairs([u | tail], acc) do
    if user_anchor?(u) do
      {mid, rest2} = Enum.split_while(tail, &(not user_anchor?(&1)))
      split_user_pairs(rest2, [{u, mid} | acc])
    else
      split_user_pairs(tail, acc)
    end
  end

  defp extract_user_id({:history, "user", _, id}), do: id
  defp extract_user_id({:user, _, id}), do: id
  defp extract_user_id({:user, _}), do: nil

  defp extract_user_text({:history, "user", c, _}), do: message_content_string(c)
  defp extract_user_text({:user, c, _}), do: message_content_string(c)
  defp extract_user_text({:user, c}), do: message_content_string(c)

  defp chat_slices(log, user_edit_meta, user_variant_idx) do
    {prefix, pairs} = split_log_by_user_anchors(log)

    prefix_part =
      if prefix == [] do
        []
      else
        [{:plain, grouped_log_entries(prefix)}]
      end

    user_parts =
      Enum.map(pairs, fn {u_entry, mid_entries} ->
        id = extract_user_id(u_entry)
        id_key = if id, do: to_string(id), else: nil
        fallback = extract_user_text(u_entry)

        %{versions: versions, snapshots: snapshots} =
          if id_key && Map.has_key?(user_edit_meta, id_key) do
            Map.fetch!(user_edit_meta, id_key)
          else
            %{versions: [fallback], snapshots: []}
          end

        versions = if(versions == [], do: [fallback], else: versions)
        n = length(versions)
        max_i = n - 1

        raw_idx =
          if id_key do
            Map.get(user_variant_idx, id_key, max_i)
          else
            max_i
          end

        idx = min(max(0, raw_idx), max_i)
        display_text = Enum.at(versions, idx)

        follow_raw =
          if idx < max_i do
            decode_snapshot(Enum.at(snapshots, idx))
          else
            mid_entries
          end

        {:user_turn, id_key, display_text, versions, idx, grouped_log_entries(follow_raw)}
      end)

    prefix_part ++ user_parts
  end

  defp encode_snapshot(entries) when is_list(entries) do
    Jason.encode!(Enum.map(entries, &encode_log_entry/1))
  end

  defp encode_log_entry({:assistant, c, id}) when not is_nil(id) do
    %{"k" => "as", "c" => c, "i" => to_string(id)}
  end

  defp encode_log_entry({:assistant, c}), do: %{"k" => "as", "c" => c}

  defp encode_log_entry({:user, c, id}),
    do: %{"k" => "u", "c" => c, "i" => to_string(id)}

  defp encode_log_entry({:history, "user", c, id}),
    do: %{"k" => "hu", "c" => c, "i" => to_string(id)}

  defp encode_log_entry({:history, "assistant", c}), do: %{"k" => "ha", "c" => c}

  defp encode_log_entry({:reasoning, c}), do: %{"k" => "r", "c" => c}

  defp encode_log_entry({:stopped, id}), do: %{"k" => "stopped", "i" => to_string(id)}

  defp encode_log_entry({:tool_start, id, n, a}) do
    %{"k" => "ts", "id" => id, "n" => n, "a" => json_safe_for_snapshot(a)}
  end

  defp encode_log_entry({:tool_start, n, a}) do
    %{"k" => "ts", "n" => to_string(n), "a" => json_safe_for_snapshot(a)}
  end

  defp encode_log_entry({:tool_done, id, n, t}) do
    %{"k" => "td", "id" => to_string(id), "n" => to_string(n), "t" => t}
  end

  defp encode_log_entry({:tools, items}) when is_list(items) do
    %{"k" => "tg", "items" => Enum.map(items, &encode_log_entry/1)}
  end

  defp encode_log_entry(other) do
    %{"k" => "raw", "v" => inspect(other)}
  end

  defp json_safe_for_snapshot(nil), do: nil

  defp json_safe_for_snapshot(v) when is_map(v) do
    v
    |> Enum.map(fn {k, val} ->
      {json_safe_key_str(k), json_safe_for_snapshot(val)}
    end)
    |> Map.new()
  end

  defp json_safe_for_snapshot(v) when is_list(v), do: Enum.map(v, &json_safe_for_snapshot/1)

  defp json_safe_for_snapshot(v) when is_atom(v) do
    case Atom.to_string(v) do
      "Elixir." <> rest -> rest
      s -> s
    end
  end

  defp json_safe_for_snapshot(v), do: v

  defp json_safe_key_str(k) when is_atom(k), do: Atom.to_string(k)
  defp json_safe_key_str(k), do: to_string(k)

  defp decode_snapshot(nil), do: []
  defp decode_snapshot(""), do: []

  defp decode_snapshot(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, list} when is_list(list) -> Enum.flat_map(list, &decode_log_entry_map/1)
      _ -> []
    end
  end

  defp decode_snapshot(list) when is_list(list), do: Enum.flat_map(list, &decode_log_entry_map/1)
  defp decode_snapshot(_), do: []

  defp decode_log_entry_map(m) when is_map(m) do
    k = Map.get(m, "k") || Map.get(m, :k)

    case k do
      "as" ->
        c = Map.get(m, "c") || Map.get(m, :c) || ""
        i = Map.get(m, "i") || Map.get(m, :i)

        if i && i != "" do
          [{:assistant, c, i}]
        else
          [{:assistant, c}]
        end

      "u" ->
        c = Map.get(m, "c") || Map.get(m, :c) || ""
        i = Map.get(m, "i") || Map.get(m, :i)
        [{:user, c, i}]

      "hu" ->
        c = Map.get(m, "c") || Map.get(m, :c) || ""
        i = Map.get(m, "i") || Map.get(m, :i)
        [{:history, "user", c, i}]

      "ha" ->
        [{:history, "assistant", Map.get(m, "c") || Map.get(m, :c) || ""}]

      "r" ->
        [{:reasoning, Map.get(m, "c") || Map.get(m, :c) || ""}]

      "stopped" ->
        [{:stopped, Map.get(m, "i") || Map.get(m, :i)}]

      "ts" ->
        n = Map.get(m, "n") || Map.get(m, :n) || "tool"
        a = Map.get(m, "a") || Map.get(m, :a) || %{}

        case Map.get(m, "id") do
          nil -> [{:tool_start, n, a}]
          id -> [{:tool_start, id, n, a}]
        end

      "td" ->
        id = Map.get(m, "id") || Map.get(m, :id) || "call"
        n = Map.get(m, "n") || Map.get(m, :n) || "tool"
        t = Map.get(m, "t") || Map.get(m, :t) || ""
        [{:tool_done, id, n, t}]

      "tg" ->
        items = Map.get(m, "items") || Map.get(m, :items) || []
        decoded = Enum.flat_map(List.wrap(items), &decode_log_entry_map/1)
        [{:tools, decoded}]

      _ ->
        []
    end
  end

  defp decode_log_entry_map(_), do: []

  defp db_tail_log_entries(session_id, user_msg_id) do
    msgs = Agents.list_messages(session_id)

    case Enum.split_while(msgs, &(&1.id != user_msg_id)) do
      {_, [_anchor | rest]} ->
        rest
        |> Enum.take_while(&(&1.role != "user"))
        |> Enum.flat_map(&message_to_log_fragment/1)

      _ ->
        []
    end
  end

  defp reload_chat_from_db(%{assigns: %{session: %{id: sid}}} = socket) do
    msgs = Agents.list_messages(sid)

    socket
    |> assign(:log, history_entries(msgs))
    |> assign(:user_edit_meta, build_user_edit_meta(msgs))
    |> assign(:agent_busy, composer_agent_busy?(sid))
  end

  defp reload_chat_from_db(socket), do: socket

  defp assistant_plaintext_from_db(socket, id_str) when is_binary(id_str) do
    with %{session: %{id: sid}} <- socket.assigns,
         {:ok, uuid} <- Ecto.UUID.cast(String.trim(id_str)),
         %AgentMessage{role: "assistant", content: c, session_id: msid} <-
           Agents.get_message(uuid),
         true <- to_string(sid) == to_string(msid) do
      message_content_string(c)
    else
      _ -> nil
    end
  end

  defp assistant_plaintext_from_db(_, _), do: nil

  defp context_menu_style(%{top: t, right: r}) do
    left = max(8, r - 208)
    "left: #{left}px; top: #{t}px; transform: translateY(calc(-100% - 6px));"
  end

  defp md_html(text), do: FluxClawWeb.Markdown.render(text)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} variant={:bare}>
      <div
        id="app-frame"
        class="workbench flex h-dvh overflow-hidden"
        phx-window-keydown="close_drawers"
        phx-key="Escape"
      >
        <div
          :if={@sidebar_open}
          class="fixed inset-0 z-40 bg-black/40 lg:hidden"
          phx-click="toggle_sidebar"
        >
        </div>

        <aside
          class={[
            "fixed lg:static inset-y-0 left-0 z-50 flex flex-col border-r border-zinc-200/80 bg-white transition-transform duration-200 [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900 lg:translate-x-0",
            if(@sidebar_open, do: "translate-x-0", else: "-translate-x-full"),
            if(@sidebar_collapsed, do: "w-14", else: "w-[min(248px,88vw)] lg:w-[248px]")
          ]}
          id="sidebar-root"
        >
          <div class="flex h-12 items-center gap-2 border-b border-zinc-200/80 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
            <%= if @sidebar_collapsed do %>
              <button
                type="button"
                phx-click="toggle_sidebar_rail"
                class="rounded-lg p-2 text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="展开侧栏"
                aria-label="展开侧栏"
              >
                <.icon name="hero-ellipsis-horizontal" class="size-5" />
              </button>
            <% else %>
              <span class="flex items-center gap-2 font-semibold tracking-tight text-[15px]">
                <img src={~p"/images/fluxclaw-assistant.png"} alt="" class="size-6 rounded-md" />
                FluxClaw
              </span>
              <span class="ml-auto text-[10px] font-medium uppercase tracking-wider text-zinc-400">
                Workbench
              </span>
            <% end %>
          </div>

          <%= if @sidebar_collapsed do %>
            <div class="flex flex-1 flex-col items-center gap-1 py-2">
              <button
                type="button"
                phx-click="new_chat"
                class="rounded-lg p-2 text-emerald-600 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="新建对话"
                aria-label="新建对话"
              >
                <.icon name="hero-plus" class="size-5" />
              </button>
              <button
                type="button"
                phx-click="toggle_nav"
                phx-value-section="projects"
                class="rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="项目 / 对话"
                aria-label="项目"
              >
                <.icon name="hero-folder" class="size-5" />
              </button>
              <button
                type="button"
                phx-click="toggle_nav"
                phx-value-section="skills"
                class="rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="技能 (L3)"
                aria-label="技能"
              >
                <.icon name="hero-bolt" class="size-5" />
              </button>
              <button
                type="button"
                phx-click="toggle_nav"
                phx-value-section="memory"
                class="rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title="Memory 文档"
                aria-label="Memory"
              >
                <.icon name="hero-book-open" class="size-5" />
              </button>
            </div>
          <% else %>
            <div class="flex flex-1 flex-col min-h-0 overflow-hidden">
              <button id="new-task" type="button" phx-click="new_chat" class="wb-new-task">
                <.icon name="hero-plus" class="size-4" /> 新建对话
                <span class="ml-auto text-[10px] opacity-60">NEW TASK</span>
              </button>
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

              <section class="flex flex-col min-h-0 border-b border-zinc-100 [[data-theme=dark]_&]:border-zinc-800 flex-1">
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

              <button
                id="project-resources"
                type="button"
                phx-click="set_right_tab"
                phx-value-tab="memory"
                class="wb-resource-link"
              >
                <.icon name="hero-square-3-stack-3d" class="size-4" /> 项目资源与技能
                <.icon name="hero-chevron-right" class="ml-auto size-3" />
              </button>
            </div>
          <% end %>

          <div class="border-t border-zinc-200/80 p-2 flex items-center justify-between gap-2 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
            <button
              type="button"
              phx-click="toggle_settings"
              class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
            >
              <.icon name="hero-cog-6-tooth" class="size-5" />
              <span :if={!@sidebar_collapsed}>设置</span>
            </button>
            <button
              type="button"
              id="fluxclaw-theme-toggle"
              phx-hook="ThemeToggle"
              class="rounded-lg border border-zinc-200 p-2 text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
              title="切换浅色 / 深色"
            >
              <span data-theme-icon="moon" class="hidden block">
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
            class="fixed inset-0 z-[52] bg-black/40 lg:left-[17.5rem]"
            phx-click="close_skill_editor"
          >
          </div>
          <aside
            class={[
              "fixed top-0 bottom-0 z-[53] flex w-[min(52rem,100vw)] flex-col border-r border-zinc-200 bg-white shadow-2xl transition-transform duration-300 ease-out [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900",
              "left-0 lg:left-[17.5rem] translate-x-0"
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
          <header class="flex h-12 items-center gap-1.5 border-b border-zinc-200/80 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
            <button
              id="navigation-toggle"
              type="button"
              phx-click="toggle_sidebar"
              class="rounded-lg p-2 text-zinc-600 hover:bg-zinc-100 lg:hidden [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
              aria-label="菜单"
              aria-expanded={to_string(@sidebar_open)}
              aria-controls="sidebar-root"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="toggle_sidebar_rail"
              class="hidden lg:block rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-300 [[data-theme=dark]_&]:hover:bg-zinc-800"
              title={if(@sidebar_collapsed, do: "展开侧栏", else: "收起侧栏")}
              aria-label="收起 / 展开侧栏"
            >
              <.icon
                name={
                  if(@sidebar_collapsed,
                    do: "hero-ellipsis-horizontal",
                    else: "hero-bars-3-center-left"
                  )
                }
                class="size-5"
              />
            </button>
            <div class="flex-1 min-w-0 px-1">
              <p class="wb-breadcrumb">{(@project && @project.title) || "工作空间"} <span>/</span></p>
              <h1 class="text-[14px] font-medium truncate">
                {(@session && @session.title) || "新任务"}
              </h1>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <button
                type="button"
                phx-click="toggle_right"
                class="flex items-center rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
                title={if(@right_open, do: "隐藏面板", else: "显示面板")}
                id="details-toggle"
                aria-label="切换右侧面板"
                aria-expanded={to_string(@right_open)}
                aria-controls="sidebar-right"
              >
                <.icon
                  name={
                    if(@right_open,
                      do: "hero-arrow-right-on-rectangle",
                      else: "hero-bars-3-center-left"
                    )
                  }
                  class="size-5"
                />
                <span class="ml-1 text-xs">详情</span>
              </button>
            </div>
          </header>

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

          <div
            id="chat-scroll"
            phx-hook="ChatScroll"
            class="wb-chat-scroll"
            data-external-link-event="external_link_click"
          >
            <div class="wb-conversation">
              <section :if={@log == []} id="workbench-welcome" class="wb-welcome">
                <div class="wb-eyebrow"><span class="wb-status-dot"></span> FLUXCLAW WORKBENCH</div>
                <h2>想完成什么任务？</h2>
                <p>从一个想法，到一份可以交付的成果。<br />一起研究、编写、构建，让工作向前一步。</p>
                <div class="wb-examples">
                  <button
                    id="example-research"
                    type="button"
                    phx-click="fill_example"
                    phx-value-text="搜索这个主题的可靠资料，注明来源并整理研究结论："
                    class="wb-example"
                  >
                    <.icon name="hero-globe-alt" class="size-5" /><strong>研究一个主题</strong><span>搜索资料，交叉核实，整理结论</span>
                  </button>
                  <button
                    id="example-build"
                    type="button"
                    phx-click="fill_example"
                    phx-value-text="请帮我实现这个功能，先制定计划，再编写代码并验证："
                    class="wb-example"
                  >
                    <.icon name="hero-command-line" class="size-5" /><strong>构建与验证</strong><span>从任务计划到代码与执行结果</span>
                  </button>
                  <button
                    id="example-organize"
                    type="button"
                    phx-click="fill_example"
                    phx-value-text="把下面的内容整理成清晰的行动清单，并保存为 Markdown 文件："
                    class="wb-example"
                  >
                    <.icon name="hero-document-text" class="size-5" /><strong>整理成可用成果</strong><span>提炼重点，生成文档与行动清单</span>
                  </button>
                </div>
              </section>
              <div id="conversation-turns" phx-update="stream">
                <article :for={{dom_id, turn} <- @streams.turns} id={dom_id} class="wb-turn">
                  <%= case turn.slice do %>
                    <% {:plain, grouped} -> %>
                      <%= for entry <- grouped do %>
                        <%= case entry do %>
                          <% {:tools, items} -> %>
                            <.tools_flow_block items={items} />
                          <% _ -> %>
                            <.chat_bubble entry={entry} />
                        <% end %>
                      <% end %>
                    <% {:user_turn, msg_id, display_text, versions, vidx, grouped_follow} -> %>
                      <.user_message_block
                        msg_id={msg_id || ""}
                        content={display_text}
                        versions={versions}
                        variant_idx={vidx}
                        editing_user={@editing_user_msg}
                        follow_entries={grouped_follow}
                      />
                  <% end %>
                </article>
              </div>
              <details
                :if={@draft_reasoning not in [nil, ""]}
                id="model-reasoning"
                class="wb-reasoning"
              >
                <summary>模型推理 · 点击查看模型返回的内容</summary>
                <div class="chat-md">{raw(md_html(@draft_reasoning))}</div>
              </details>
              <div
                :if={@draft_assistant not in [nil, ""]}
                id="streaming-answer"
                class="wb-assistant chat-md"
              >
                {raw(md_html(@draft_assistant))}
              </div>
              <div
                :if={@agent_busy || @run_status}
                id="agent-status"
                class="wb-run-status"
                role="status"
                aria-live="polite"
              >
                <span :if={@agent_busy} class="wb-status-dot animate-pulse"></span>
                {if(@agent_busy, do: "正在处理任务…", else: @run_status)}
              </div>
              <section :if={@pending_ask} id="agent-question" class="wb-action-card">
                <div class="wb-eyebrow">
                  <.icon name="hero-chat-bubble-left-right" class="size-4" /> 等待你的回复
                </div>
                <p>{@pending_ask.question}</p>
                <.form for={@answer_form} id="ask-user-form" phx-submit="answer_user">
                  <.input type="hidden" name="ref" value={@pending_ask.ref} />
                  <.input
                    field={@answer_form[:text]}
                    id="ask-user-text"
                    type="textarea"
                    rows="2"
                    class="wb-answer-input"
                    placeholder="输入回复，继续任务…"
                    required
                  />
                  <button id="answer-submit" type="submit" class="wb-primary">
                    回复并继续 <.icon name="hero-arrow-right" class="size-4" />
                  </button>
                </.form>
              </section>
              <.diff_review_block :if={@pending_diff} pending_diff={@pending_diff} />
            </div>
          </div>
          <button id="jump-to-latest" type="button" class="wb-jump hidden" aria-label="回到最新">
            <.icon name="hero-arrow-down" class="size-4" /> 回到最新
          </button>
          <section
            :if={@skill_proposal}
            id="skill-proposal"
            class="wb-action-card mx-auto w-full max-w-[760px] mb-3"
          >
            <h3 class="font-semibold">将这次经验保存为技能</h3>
            <p class="mt-2 text-sm">{@skill_proposal.title}</p>
            <details class="mt-2 text-xs">
              <summary>预览技能正文</summary>
              <pre class="whitespace-pre-wrap max-h-48 overflow-auto mt-2">{Map.get(@skill_proposal, :body, "")}</pre>
            </details>
            <div class="mt-3 flex gap-2">
              <button
                id="save-proposed-skill"
                type="button"
                phx-click="accept_skill_proposal"
                class="wb-secondary"
              >
                保存技能
              </button>
              <button
                id="dismiss-proposed-skill"
                type="button"
                phx-click="dismiss_skill_proposal"
                class="wb-secondary"
              >
                忽略
              </button>
            </div>
          </section>
          <.workbench_composer
            form={@composer_form}
            agent_busy={@agent_busy}
            pending_ask={@pending_ask}
            session_id={@session && @session.id}
            project_id={@project && @project.id}
            settings={@settings_form}
          />
        </main>

        <div
          :if={@right_open}
          class="fixed inset-0 z-40 bg-black/40 xl:hidden"
          phx-click="toggle_right"
        >
        </div>

        <aside
          id="sidebar-right"
          class={[
            "flex-col border-l border-zinc-200/80 bg-white [[data-theme=dark]_&]:border-zinc-800 [[data-theme=dark]_&]:bg-zinc-900",
            "max-xl:fixed max-xl:inset-y-0 max-xl:right-0 max-xl:z-50 max-xl:w-[min(24rem,92vw)] max-xl:shadow-2xl",
            "xl:relative xl:w-[320px] xl:shrink-0",
            if(@right_open, do: "flex translate-x-0", else: "max-xl:hidden xl:hidden")
          ]}
        >
          <div class="flex h-12 items-center gap-2 border-b border-zinc-200/80 px-3 shrink-0 [[data-theme=dark]_&]:border-zinc-800">
            <span class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
              {right_tab_title(@right_tab)}
            </span>
            <button
              type="button"
              phx-click="toggle_right"
              class="ml-auto rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800"
              aria-label="关闭面板"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <nav class="wb-detail-tabs" aria-label="详情分类">
            <button
              :for={
                {tab, label} <- [
                  {"memory", "项目资源"},
                  {"timeline", "运行轨迹"},
                  {"plugins", "工具集成"},
                  {"files", "文件"}
                ]
              }
              id={"detail-tab-#{tab}"}
              type="button"
              phx-click="set_right_tab"
              phx-value-tab={tab}
              aria-selected={to_string(Atom.to_string(@right_tab) == tab)}
            >
              {label}
            </button>
          </nav>
          <div class="flex-1 min-h-0 overflow-y-auto p-3">
            <%= case @right_tab do %>
              <% :plugins -> %>
                <.native_integrations form={@integration_form} />
                <.plugin_panel plugins_info={@plugins_info} />
              <% :files -> %>
                <div id="artifact-panel" class="space-y-4">
                  <p class="text-sm text-zinc-500">当前会话的实际文件 · 最多展示 150 项</p>
                  <button
                    id="refresh-artifacts"
                    type="button"
                    phx-click="refresh_artifacts"
                    class="wb-secondary"
                  >
                    刷新文件
                  </button>
                  <.form
                    :if={@session}
                    for={@attachment_form}
                    id="attachment-form"
                    phx-change="validate_upload"
                    phx-submit="upload_files"
                    class="space-y-3"
                  >
                    <label for={@uploads.attachments.ref} class="text-sm">添加附件（每个不超过 8 MB）</label>
                    <.live_file_input upload={@uploads.attachments} class="w-full text-xs" />
                    <div :for={entry <- @uploads.attachments.entries} class="text-xs break-all">
                      {entry.client_name} · {entry.progress}%<span
                        :for={error <- upload_errors(@uploads.attachments, entry)}
                        class="block text-red-600"
                      >{error}</span>
                    </div>
                    <p
                      :for={error <- upload_errors(@uploads.attachments)}
                      class="text-xs text-red-600"
                    >
                      {error}
                    </p>
                    <button id="upload-attachments" type="submit" class="wb-secondary">保存附件</button>
                  </.form>
                  <div id="artifact-files" phx-update="stream" class="space-y-2">
                    <p id="artifacts-empty" class="hidden only:block text-sm text-zinc-500">
                      点击刷新查看文件。先创建任务即可上传附件。
                    </p>
                    <article :for={{id, file} <- @streams.artifacts} id={id} class="wb-file-card">
                      <p class="break-all text-sm font-medium">{file.path}</p>
                      <p class="text-xs text-zinc-500">{file.size} bytes</p>
                      <div :if={@session} class="mt-2 flex gap-3 text-xs">
                        <a href={artifact_url(@session.id, file.path)} target="_blank" rel="noopener">
                          预览
                        </a>
                        <a href={artifact_url(@session.id, file.path) <> "?download=1"} download>
                          下载
                        </a>
                      </div>
                    </article>
                  </div>
                </div>
              <% :memory -> %>
                <.memory_panel
                  skills={@skills_sidebar}
                  memory_doc_files={@memory_doc_files}
                  checkpoints={@checkpoints}
                />
              <% _ -> %>
                <.timeline_panel
                  agent_busy={@agent_busy}
                  checkpoints={@checkpoints}
                  log={@log}
                  pending_ask={@pending_ask}
                  pending_diff={@pending_diff}
                />
            <% end %>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :agent_busy, :boolean, required: true
  attr :pending_ask, :any, required: true
  attr :session_id, :any, default: nil
  attr :project_id, :any, default: nil
  attr :settings, :map, required: true

  defp workbench_composer(assigns) do
    ~H"""
    <div class="wb-composer-area">
      <div :if={@settings["api_key"] in [nil, ""]} id="model-setup-notice" class="wb-model-notice">
        配置模型后即可开始任务。<button type="button" id="open-model-settings" phx-click="toggle_settings">打开模型设置 <.icon
            name="hero-arrow-up-right"
            class="size-3"
          /></button>
      </div>
      <div :if={@pending_ask} class="wb-composer-hint">等待你的回复 · 当前草稿已保留</div>
      <.form for={@form} id="chat-send-form" phx-submit="send" class="wb-composer">
        <.input
          field={@form[:text]}
          type="textarea"
          id={"chat-composer-" <> (@session_id || @project_id || "home")}
          rows="2"
          class="wb-composer-input"
          phx-hook="ChatComposer"
          phx-update="ignore"
          data-draft-key={@session_id || @project_id || "home"}
          placeholder="描述任务，或继续一个想法…"
          autocomplete="off"
        />
        <div class="wb-composer-toolbar">
          <button
            id="composer-model"
            type="button"
            phx-click="toggle_settings"
            class="wb-model-picker"
          >
            <.icon name="hero-cube-transparent" class="size-4" />{@settings["model"] || "配置模型"}<.icon
              name="hero-chevron-down"
              class="size-3"
            />
          </button>
          <span class="wb-composer-shortcut">Enter 发送 · Shift+Enter 换行</span>
          <button
            :if={@agent_busy}
            type="button"
            id="chat-stop-btn"
            phx-click="stop_agent"
            class="wb-send"
            aria-label="停止当前任务"
            title="停止当前任务"
          >
            <.icon name="hero-stop-solid" class="size-4" />
          </button>
          <button
            :if={!@agent_busy}
            type="submit"
            id="chat-send-btn"
            disabled={@pending_ask != nil}
            class="wb-send"
            aria-label="发送任务"
            title="发送任务"
          >
            <.icon name="hero-arrow-up" class="size-5" />
          </button>
        </div>
      </.form>
      <p class="wb-composer-footnote">FluxClaw 可以使用工具完成任务。请核实关键结果。</p>
    </div>
    """
  end

  defp right_tab_title(:files), do: "附件与产物"
  defp right_tab_title(:plugins), do: "工具集成"
  defp right_tab_title(:memory), do: "项目资源"
  defp right_tab_title(:timeline), do: "运行轨迹"

  attr :pending_diff, :map, required: true

  defp diff_review_block(assigns) do
    assigns = assign(assigns, :diff_lines, diff_lines(assigns.pending_diff["diff"]))

    ~H"""
    <div class="shrink-0 border-t border-indigo-300/50 bg-indigo-50/60 px-3 py-3 [[data-theme=dark]_&]:border-indigo-900/40 [[data-theme=dark]_&]:bg-indigo-950/25">
      <div class="mx-auto w-full max-w-[46.75rem]">
        <div class="flex flex-wrap items-center gap-2">
          <span class="flex items-center gap-1.5 text-sm font-medium text-indigo-900 [[data-theme=dark]_&]:text-indigo-200">
            <.icon name="hero-code-bracket" class="size-4" /> 代码修改待确认
          </span>
          <span class="rounded-md bg-white/70 px-2 py-0.5 font-mono text-[11px] text-zinc-600 [[data-theme=dark]_&]:bg-zinc-900/60 [[data-theme=dark]_&]:text-zinc-300">
            {@pending_diff["path"]}
          </span>
          <span class="text-[11px] text-zinc-500">
            来源工具 {@pending_diff["tool"]}
          </span>
          <div class="ml-auto flex gap-2">
            <button
              type="button"
              phx-click="review_diff"
              phx-value-ref={@pending_diff["ref"]}
              phx-value-decision="keep"
              id="diff-review-keep"
              class="rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700"
            >
              保留修改
            </button>
            <button
              type="button"
              phx-click="review_diff"
              phx-value-ref={@pending_diff["ref"]}
              phx-value-decision="reject"
              id="diff-review-reject"
              class="rounded-lg border border-zinc-300 px-3 py-1.5 text-xs [[data-theme=dark]_&]:border-zinc-600"
            >
              拒绝
            </button>
          </div>
        </div>
        <div class="dsh-diff mt-2 max-h-64 overflow-y-auto rounded-lg border border-indigo-200/70 bg-white font-mono text-[11px] leading-5 [[data-theme=dark]_&]:border-indigo-900/40 [[data-theme=dark]_&]:bg-zinc-900/70">
          <%= for {tag, line} <- @diff_lines do %>
            <pre class={[
              "m-0 whitespace-pre-wrap px-3 py-px",
              tag == :add && "dsh-diff-add",
              tag == :del && "dsh-diff-del",
              tag == :meta && "dsh-diff-meta",
              tag == :ctx && "text-zinc-600 [[data-theme=dark]_&]:text-zinc-400"
            ]}>{line}</pre>
          <% end %>
        </div>
        <p class="mt-1.5 text-[11px] text-zinc-500">
          选择「保留修改」后文件才会写入；拒绝则不产生任何变更，Agent 会继续处理。
        </p>
      </div>
    </div>
    """
  end

  defp artifact_url(sid, path),
    do:
      "/artifacts/" <>
        sid <>
        "/" <>
        Enum.map_join(Path.split(path), "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

  attr :form, :any, required: true

  defp native_integrations(assigns) do
    ~H"""
    <section id="native-integrations" class="wb-integration space-y-3 mb-5">
      <h3 class="font-semibold">原生 LLM 工具</h3>
      <p class="text-xs text-zinc-500">
        AgentSearch 检索知识索引；Harness² 使用当前模型改进文本任务，复用会话内的经验。配置后由模型直接调用。
      </p>
      <.form for={@form} id="integration-settings" phx-submit="save_integrations" class="space-y-3">
        <.input
          field={@form[:search_url]}
          label="AgentSearch 服务地址"
          placeholder="http://127.0.0.1:8000"
        />
        <.input
          field={@form[:search_mode]}
          type="select"
          label="服务协议"
          options={[{"自托管 AgentSearch", "local"}, {"SciPhi 托管接口", "sciphi"}]}
        />
        <.input
          field={@form[:search_key]}
          type="password"
          label="搜索 API Key（留空保留）"
          autocomplete="new-password"
        />
        <p class="text-xs text-zinc-500">搜索需要独立部署、导入数据的 AgentSearch 服务；空地址表示未配置。环境变量优先于此处设置。</p>
        <.input field={@form[:python]} label="Python 3.12 / 3.13 可执行文件" />
        <p class="text-xs text-zinc-500">
          Harness² 源码已内置，无需外部 CLI。可让 Agent 调用 harness2_optimize 的 demo 操作验证环境。
        </p>
        <button id="save-integrations" type="submit" class="wb-secondary">保存工具配置</button>
      </.form>
    </section>
    """
  end

  attr :plugins_info, :map, required: true

  defp plugin_panel(assigns) do
    assigns = assign(assigns, :info, assigns.plugins_info || %{})

    ~H"""
    <div id="plugin-panel" class="space-y-3">
      <div class="rounded-xl border border-zinc-200 p-3 [[data-theme=dark]_&]:border-zinc-800">
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm font-semibold">Cordis 运行时</span>
          <span class={[
            "rounded-full px-2 py-0.5 text-[11px] font-medium",
            @info[:runtime_ready] == true &&
              "bg-emerald-100 text-emerald-700 [[data-theme=dark]_&]:bg-emerald-900/40 [[data-theme=dark]_&]:text-emerald-300",
            @info[:runtime_ready] != true &&
              "bg-zinc-100 text-zinc-500 [[data-theme=dark]_&]:bg-zinc-800 [[data-theme=dark]_&]:text-zinc-400"
          ]}>
            {if(@info[:runtime_ready] == true, do: "运行中", else: "未运行")}
          </span>
        </div>
        <p class="mt-2 text-[11px] text-zinc-500 break-all">
          配置：{@info[:config_path]}
        </p>
        <div class="mt-1 text-[11px] text-zinc-500">
          插件 {length(@info[:plugins] || [])} ·
          工具 {length(@info[:tools] || [])} ·
          提示段 {length(@info[:prompt_sections] || [])}
        </div>
        <button
          type="button"
          phx-click="refresh_plugins"
          class="mt-2 rounded-lg border border-zinc-300 px-2.5 py-1 text-xs hover:bg-zinc-100 [[data-theme=dark]_&]:border-zinc-700 [[data-theme=dark]_&]:hover:bg-zinc-800"
        >
          刷新状态
        </button>
      </div>

      <%= if @info[:config_found] != true do %>
        <div class="rounded-xl border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 [[data-theme=dark]_&]:border-zinc-700">
          未找到 cordis 配置。复制 <code class="font-mono">.fluxclaw/cordis.example.yml</code>
          为 <code class="font-mono">.fluxclaw/cordis.yml</code>
          即可启用 DeepSeek Harness 插件（npm 或本地 .mjs）。
        </div>
      <% end %>

      <%= for p <- @info[:plugins] || [] do %>
        <div class="rounded-xl border border-zinc-200 p-3 [[data-theme=dark]_&]:border-zinc-800">
          <div class="flex items-center gap-2">
            <span class="min-w-0 flex-1 truncate text-sm font-medium">{p.name || p.id}</span>
            <span class={[
              "shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium",
              p.loaded &&
                "bg-emerald-100 text-emerald-700 [[data-theme=dark]_&]:bg-emerald-900/40 [[data-theme=dark]_&]:text-emerald-300",
              !p.loaded &&
                "bg-zinc-100 text-zinc-500 [[data-theme=dark]_&]:bg-zinc-800 [[data-theme=dark]_&]:text-zinc-400"
            ]}>
              {if(p.loaded, do: "已加载", else: "未加载")}
            </span>
          </div>
          <div class="mt-1 flex items-center gap-2 text-[11px] text-zinc-500">
            <span class="rounded bg-zinc-100 px-1.5 py-0.5 font-mono [[data-theme=dark]_&]:bg-zinc-800">
              {if(p.source_kind == :local, do: "local", else: "npm")}
            </span>
            <span class="truncate">{p.id}</span>
            <span class="shrink-0">{length(p.tools)} 工具</span>
          </div>
        </div>
      <% end %>

      <%= if (@info[:tools] || []) != [] do %>
        <div class="rounded-xl border border-zinc-200 p-3 [[data-theme=dark]_&]:border-zinc-800">
          <p class="text-sm font-semibold mb-2">插件工具</p>
          <ul class="space-y-2">
            <%= for t <- @info[:tools] || [] do %>
              <li class="text-xs">
                <span class="font-mono text-emerald-600 [[data-theme=dark]_&]:text-emerald-400">
                  {t.function.name}
                </span>
                <span class="block text-zinc-500 line-clamp-2">
                  {t.function.description}
                </span>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= if (@info[:prompt_sections] || []) != [] do %>
        <div class="rounded-xl border border-zinc-200 p-3 [[data-theme=dark]_&]:border-zinc-800">
          <p class="text-sm font-semibold mb-2">注册的提示段</p>
          <ul class="space-y-1 text-xs text-zinc-600 [[data-theme=dark]_&]:text-zinc-400">
            <%= for s <- @info[:prompt_sections] || [] do %>
              <li class="truncate">
                <span class="font-medium">{s.title}</span>
                <span class="text-zinc-400">· 优先级 {s.priority}</span>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </div>
    """
  end

  attr :skills, :list, required: true
  attr :memory_doc_files, :list, required: true
  attr :checkpoints, :list, required: true

  defp memory_panel(assigns) do
    ~H"""
    <div id="memory-panel" class="space-y-4">
      <div class="flex gap-2">
        <button id="add-skill" type="button" phx-click="open_skill_editor_new" class="wb-secondary">
          新建技能
        </button>
        <button
          id="import-skill"
          type="button"
          phx-click="open_skill_import"
          class="wb-secondary"
        >
          导入技能
        </button>
      </div>
      <section>
        <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">检查点 (L1/L2)</p>
        <%= if @checkpoints == [] do %>
          <p class="mt-1 text-xs text-zinc-400">暂无工作检查点</p>
        <% else %>
          <ul class="mt-1 space-y-1">
            <%= for c <- Enum.take(@checkpoints, 8) do %>
              <li class="truncate rounded-lg px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-400 [[data-theme=dark]_&]:hover:bg-zinc-800">
                <span class="font-medium">{c.label || "checkpoint"}</span>
                <span class="text-zinc-400">· {Calendar.strftime(c.inserted_at, "%m-%d %H:%M")}</span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </section>

      <section>
        <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">技能 (L3)</p>
        <%= if @skills == [] do %>
          <p class="mt-1 text-xs text-zinc-400">暂无技能，工具回合结束后会尝试结晶</p>
        <% else %>
          <ul class="mt-1 space-y-0.5">
            <%= for sk <- @skills do %>
              <li class="group flex items-center gap-1 rounded-lg px-2 py-1 hover:bg-zinc-100 [[data-theme=dark]_&]:hover:bg-zinc-800">
                <span class="min-w-0 flex-1 truncate text-xs" title={sk.title}>{sk.title}</span>
                <button
                  type="button"
                  id={"right-panel-skill-#{sk.id}"}
                  phx-hook="SidebarContextMenu"
                  data-menu-type="skill"
                  data-menu-id={sk.id}
                  class="p-1 rounded text-zinc-400 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700 shrink-0"
                  aria-label="技能菜单"
                >
                  <.icon name="hero-ellipsis-vertical" class="size-3.5" />
                </button>
              </li>
            <% end %>
          </ul>
        <% end %>
      </section>

      <section>
        <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Memory 文档</p>
        <%= if @memory_doc_files == [] do %>
          <p class="mt-1 text-xs text-zinc-400">memory 目录下暂无文档</p>
        <% else %>
          <ul class="mt-1 space-y-0.5">
            <%= for f <- @memory_doc_files do %>
              <li
                class="truncate rounded-lg px-2 py-1 text-xs text-zinc-500 [[data-theme=dark]_&]:text-zinc-400"
                title={f.path}
              >
                {f.name}
              </li>
            <% end %>
          </ul>
        <% end %>
        <p class="mt-2 text-[11px] text-zinc-400 leading-relaxed">
          自进化摘要写入 <code class="font-mono">evolution_episodes.md</code>；确认模式下提案会出现在聊天顶部。
        </p>
      </section>
    </div>
    """
  end

  attr :agent_busy, :boolean, required: true
  attr :checkpoints, :list, required: true
  attr :log, :list, required: true
  attr :pending_ask, :any, required: true
  attr :pending_diff, :any, required: true

  defp timeline_panel(assigns) do
    tool_stats =
      assigns.log
      |> Enum.filter(&match?({:tool_done, _, _, _}, &1))
      |> Enum.map(fn {_, name, _, _} -> name end)
      |> Enum.frequencies()

    assigns = assign(assigns, :tool_stats, tool_stats)

    ~H"""
    <div class="space-y-4">
      <section class="rounded-xl border border-zinc-200 p-3 [[data-theme=dark]_&]:border-zinc-800">
        <div class="flex items-center gap-2 text-sm font-semibold">
          <span class={[
            "inline-block size-2 rounded-full",
            @agent_busy && "bg-emerald-500 animate-pulse",
            !@agent_busy && "bg-zinc-300 [[data-theme=dark]_&]:bg-zinc-700"
          ]}>
          </span>
          Agent {if(@agent_busy, do: "运行中", else: "空闲")}
        </div>
        <p class="mt-1 text-[11px] text-zinc-500">
          工具调用 {Enum.sum(Map.values(@tool_stats))} 次 · 检查点 {length(@checkpoints)} 个
        </p>
      </section>

      <%= if @pending_ask do %>
        <div class="rounded-xl border border-amber-300/60 bg-amber-50 p-3 text-xs [[data-theme=dark]_&]:border-amber-900/40 [[data-theme=dark]_&]:bg-amber-950/25">
          <p class="font-medium text-amber-900 [[data-theme=dark]_&]:text-amber-200">
            等待你的回答
          </p>
          <p class="mt-1 text-zinc-600 line-clamp-3 [[data-theme=dark]_&]:text-zinc-400">
            {@pending_ask.question}
          </p>
        </div>
      <% end %>

      <%= if @pending_diff do %>
        <div class="rounded-xl border border-indigo-300/60 bg-indigo-50 p-3 text-xs [[data-theme=dark]_&]:border-indigo-900/40 [[data-theme=dark]_&]:bg-indigo-950/25">
          <p class="font-medium text-indigo-900 [[data-theme=dark]_&]:text-indigo-200">
            代码修改待确认：{@pending_diff["path"]}
          </p>
          <p class="mt-1 text-zinc-600 [[data-theme=dark]_&]:text-zinc-400">
            在聊天底部选择保留或拒绝。
          </p>
        </div>
      <% end %>

      <%= if @tool_stats != %{} do %>
        <section>
          <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">工具使用</p>
          <ul class="mt-1 space-y-1">
            <%= for {name, count} <- Enum.sort_by(@tool_stats, fn {_, c} -> -c end) do %>
              <li class="flex items-center justify-between rounded-lg px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-100 [[data-theme=dark]_&]:text-zinc-400 [[data-theme=dark]_&]:hover:bg-zinc-800">
                <span class="font-mono">{name}</span>
                <span class="rounded-full bg-zinc-100 px-2 text-[10px] text-zinc-500 [[data-theme=dark]_&]:bg-zinc-800">
                  {count}
                </span>
              </li>
            <% end %>
          </ul>
        </section>
      <% end %>

      <%= if @checkpoints != [] do %>
        <section>
          <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">最近检查点</p>
          <ul class="mt-1 space-y-1">
            <%= for c <- Enum.take(@checkpoints, 5) do %>
              <li class="truncate rounded-lg px-2 py-1 text-xs text-zinc-600 [[data-theme=dark]_&]:text-zinc-400">
                {c.label || "checkpoint"} · {Calendar.strftime(c.inserted_at, "%H:%M")}
              </li>
            <% end %>
          </ul>
        </section>
      <% end %>
    </div>
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
    rows = FluxClaw.ToolActivity.rows(assigns.items)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:completed, Enum.count(rows, &(&1.state != :running)))

    ~H"""
    <details class="wb-tool-flow">
      <summary>
        <.icon name="hero-chevron-right" class="size-3" /><.icon
          name="hero-command-line"
          class="size-3.5"
        />
        已执行 {@completed} 步<%= if @completed < length(@rows) do %>
          · 正在运行
        <% end %>
      </summary>
      <div class="wb-tool-list">
        <details :for={row <- @rows} class="wb-tool-row" data-call-id={row.id} data-state={row.state}>
          <summary>
            <.icon
              name={if(row.state == :error, do: "hero-exclamation-circle", else: "hero-check-circle")}
              class="size-4"
            /><code>{row.name}</code><span class="truncate">{row.label}</span><span class="tool-state">{case row.state do :running -> "执行中"; :error -> "失败"; _ -> "已完成" end}</span>
          </summary>
          <p :if={row.output != nil} class="wb-tool-preview">{String.slice(row.output, 0, 240)}</p>
          <details :if={row.args != nil} class="mt-2">
            <summary>调用参数</summary>
            <pre class="wb-tool-output">{Jason.encode!(row.args, pretty: true)}</pre>
          </details>
          <details :if={row.output != nil} class="mt-2">
            <summary>完整输出</summary>
            <pre class="wb-tool-output">{row.output}</pre>
            <button
              type="button"
              phx-click={JS.dispatch("fluxclaw:copy", detail: %{text: row.output})}
              class="wb-secondary mt-2"
              aria-label="复制工具输出"
            >
              <.icon name="hero-document-duplicate" class="size-3.5" />复制输出
            </button>
          </details>
        </details>
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

  attr :msg_id, :string, default: nil
  attr :content, :string, required: true
  attr :versions, :list, required: true
  attr :variant_idx, :integer, required: true
  attr :editing_user, :any, default: nil
  attr :follow_entries, :list, required: true

  def user_message_block(assigns) do
    editing? =
      case assigns.editing_user do
        %{id: id} -> id == assigns.msg_id
        _ -> false
      end

    draft =
      case assigns.editing_user do
        %{id: id, draft: d} when id == assigns.msg_id -> d
        _ -> ""
      end

    n_variants = length(assigns.versions)
    show_nav = n_variants > 1
    show_actions = assigns.msg_id not in [nil, ""]
    can_edit = show_actions && assigns.variant_idx == n_variants - 1

    assigns =
      assigns
      |> assign(:editing?, editing?)
      |> assign(:draft, draft)
      |> assign(:edit_form, to_form(%{"text" => draft, "user_message_id" => assigns.msg_id}))
      |> assign(:n_variants, n_variants)
      |> assign(:show_nav, show_nav)
      |> assign(:show_actions, show_actions)
      |> assign(:can_edit, can_edit)

    ~H"""
    <div class="flex w-full flex-col items-stretch gap-1">
      <div class="flex w-full justify-end gap-2.5 items-end">
        <div class="flex min-w-0 max-w-[min(40rem,calc(100%-2.5rem))] flex-1 flex-col items-end">
          <%= if @editing? do %>
            <.form
              for={@edit_form}
              phx-submit="submit_user_edit"
              id={"user-edit-form-#{@msg_id}"}
              class="wb-action-card w-full"
            >
              <.input type="hidden" field={@edit_form[:user_message_id]} />
              <.input
                type="textarea"
                field={@edit_form[:text]}
                id={"user-edit-ta-#{@msg_id}"}
                rows="4"
                class="wb-answer-input"
              />
              <div class="mt-2 flex justify-end gap-2">
                <button
                  type="button"
                  phx-click="cancel_edit_user"
                  class="wb-secondary"
                >
                  取消
                </button>
                <button
                  type="submit"
                  class="wb-primary"
                >
                  发送
                </button>
              </div>
            </.form>
          <% else %>
            <div class="flex w-full max-w-full flex-col items-end">
              <div class="wb-user">
                <div class="whitespace-pre-wrap">{@content}</div>
              </div>
              <%= if @show_actions do %>
                <div class="mt-1 flex w-full max-w-full flex-row flex-wrap justify-end gap-1">
                  <button
                    type="button"
                    phx-click="copy_user_text"
                    phx-value-id={@msg_id}
                    class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-200/80 [[data-theme=dark]_&]:hover:bg-zinc-700/80"
                    title="复制"
                    aria-label="复制"
                  >
                    <.icon name="hero-document-duplicate" class="size-4" />
                  </button>
                  <%= if @can_edit do %>
                    <button
                      type="button"
                      phx-click="start_edit_user"
                      phx-value-id={@msg_id}
                      class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-200/80 [[data-theme=dark]_&]:hover:bg-zinc-700/80"
                      title="修改"
                      aria-label="修改"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if @show_nav do %>
            <div class="mt-1 flex items-center gap-2 self-end text-xs font-mono text-zinc-500 select-none [[data-theme=dark]_&]:text-zinc-400">
              <button
                type="button"
                phx-click="user_variant_step"
                phx-value-id={@msg_id}
                phx-value-dir="-1"
                class={[
                  "rounded px-2 py-0.5 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700",
                  @variant_idx <= 0 && "pointer-events-none opacity-30"
                ]}
              >
                &lt;
              </button>
              <span>{@variant_idx + 1}/{@n_variants}</span>
              <button
                type="button"
                phx-click="user_variant_step"
                phx-value-id={@msg_id}
                phx-value-dir="1"
                class={[
                  "rounded px-2 py-0.5 hover:bg-zinc-200 [[data-theme=dark]_&]:hover:bg-zinc-700",
                  @variant_idx >= @n_variants - 1 && "pointer-events-none opacity-30"
                ]}
              >
                &gt;
              </button>
            </div>
          <% end %>
        </div>
        <img
          src={~p"/images/fluxclaw-user.png"}
          alt=""
          width="32"
          height="32"
          class="mb-0.5 size-8 shrink-0 rounded-full object-cover ring-2 ring-white shadow-sm [[data-theme=dark]_&]:ring-zinc-800"
        />
      </div>
      <div class="w-full space-y-2">
        <%= for entry <- @follow_entries do %>
          <%= case entry do %>
            <% {:tools, items} -> %>
              <.tools_flow_block items={items} />
            <% _ -> %>
              <.chat_bubble entry={entry} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :entry, :any, required: true

  def chat_bubble(assigns) do
    ~H"""
    <%= case @entry do %>
      <% {:history, "user", content, _} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:history, "user", content} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:history, "assistant", content, id} -> %>
        <.bubble_assistant content={message_content_string(content)} msg_id={to_string(id)} />
      <% {:history, "assistant", content} -> %>
        <.bubble_assistant content={message_content_string(content)} />
      <% {:history, role, content} -> %>
        <.bubble_system role={to_string(role || "")} content={message_content_string(content)} />
      <% {:user, content, _} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:user, content} -> %>
        <.bubble_user content={message_content_string(content)} />
      <% {:assistant, content, id} -> %>
        <.bubble_assistant content={message_content_string(content)} msg_id={to_string(id)} />
      <% {:assistant, content} -> %>
        <.bubble_assistant content={message_content_string(content)} />
      <% {:stopped, id} -> %>
        <p id={"stopped-#{id}"} class="wb-run-status" role="status">
          <.icon name="hero-stop-circle" class="size-4" />已停止 · 已完成的操作和部分回答已保留
        </p>
      <% {:reasoning, content} -> %>
        <details class="wb-reasoning group">
          <summary class="cursor-pointer select-none list-none flex items-center gap-2 text-xs">
            <.icon
              name="hero-chevron-right"
              class="size-4 shrink-0 transition-transform group-open:rotate-90"
            />
            <.icon name="hero-sparkles" class="size-4" /> 模型推理 · 点击展开
          </summary>
          <div class="chat-md">
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
      <div class="wb-user">
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
  attr :msg_id, :string, default: ""

  def bubble_assistant(assigns) do
    html = md_html(assigns.content)
    show_bar = assigns.msg_id != ""
    assigns = assigns |> assign(:html, html) |> assign(:show_action_bar, show_bar)

    ~H"""
    <div class="flex w-full min-w-0 justify-start gap-2.5 items-start">
      <div class="flex min-w-0 flex-1 max-w-[min(48rem,100%)] flex-col items-stretch">
        <div class="wb-assistant chat-md">
          {raw(@html)}
        </div>
        <%= if @show_action_bar do %>
          <div class="mt-1 flex flex-row flex-wrap items-center gap-1 self-start">
            <button
              type="button"
              phx-click="copy_assistant_text"
              phx-value-id={@msg_id}
              class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-200/80 [[data-theme=dark]_&]:hover:bg-zinc-700/80"
              title="复制全文"
              aria-label="复制全文"
            >
              <.icon name="hero-document-duplicate" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="regenerate_assistant"
              phx-value-id={@msg_id}
              class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-200/80 [[data-theme=dark]_&]:hover:bg-zinc-700/80"
              title="重新生成"
              aria-label="重新生成"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="export_assistant_md"
              phx-value-id={@msg_id}
              class="rounded-lg p-1.5 text-zinc-500 hover:bg-zinc-200/80 [[data-theme=dark]_&]:hover:bg-zinc-700/80"
              title="导出为 Markdown"
              aria-label="导出为 Markdown"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
            </button>
          </div>
        <% end %>
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
