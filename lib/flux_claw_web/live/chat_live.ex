defmodule FluxClawWeb.ChatLive do
  use FluxClawWeb, :live_view

  alias FluxClaw.Agents
  alias FluxClaw.Agents.Orchestrator
  alias FluxClaw.Memory

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "对话")
     |> assign(:sessions, [])
     |> assign(:session, nil)
     |> assign(:log, [])
     |> assign(:draft_assistant, nil)
     |> assign(:pending_ask, nil)
     |> assign(:sidebar_open, false)
     |> assign(:skills_panel_open, true)
     |> assign(:checkpoints, [])
     |> assign(:skills_sidebar, [])
     |> assign(:chat_topic, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sessions = Agents.list_sessions()
    socket = assign(socket, :sessions, sessions)
    id = Map.get(params, "id")
    new_topic = if id, do: topic(id), else: nil

    socket = maybe_unsubscribe(socket, new_topic)

    case id do
      nil ->
        {:noreply,
         assign(socket,
           session: nil,
           log: [],
           draft_assistant: nil,
           pending_ask: nil,
           checkpoints: [],
           skills_sidebar: Memory.list_skills_recent(),
           page_title: "对话",
           chat_topic: nil
         )}

      sid ->
        case Agents.get_session(sid) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "会话不存在")
             |> push_navigate(to: ~p"/chat")}

          session ->
            log = history_entries(Agents.list_messages(session.id))
            checkpoints = Memory.list_checkpoints_for_session(session.id)
            skills_sidebar = Memory.list_skills_recent()

            socket =
              socket
              |> assign(:session, session)
              |> assign(:log, log)
              |> assign(:draft_assistant, nil)
              |> assign(:pending_ask, nil)
              |> assign(:checkpoints, checkpoints)
              |> assign(:skills_sidebar, skills_sidebar)
              |> assign(:page_title, session.title)
              |> subscribe_session(session.id)

            {:noreply, socket}
        end
    end
  end

  defp maybe_unsubscribe(socket, new_topic) do
    old = socket.assigns.chat_topic

    if old && old != new_topic && connected?(socket) do
      Phoenix.PubSub.unsubscribe(FluxClaw.PubSub, old)
    end

    socket
  end

  defp subscribe_session(socket, session_id) do
    t = topic(session_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(FluxClaw.PubSub, t)
      Orchestrator.ensure_worker(session_id)
    end

    assign(socket, :chat_topic, t)
  end

  defp topic(id), do: "agent:" <> id

  defp history_entries(messages) do
    Enum.map(messages, fn m -> {:history, m.role, m.content || ""} end)
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open, &(!&1))}
  end

  def handle_event("toggle_skills_panel", _params, socket) do
    {:noreply, update(socket, :skills_panel_open, &(!&1))}
  end

  def handle_event("new_chat", %{"title" => title}, socket) do
    title = if title in [nil, ""], do: "新对话", else: title
    {:ok, s} = Agents.create_session(%{title: title})
    {:noreply, push_navigate(socket, to: ~p"/chat/#{s.id}")}
  end

  def handle_event("new_chat", _params, socket) do
    {:ok, s} = Agents.create_session(%{title: "新对话"})
    {:noreply, push_navigate(socket, to: ~p"/chat/#{s.id}")}
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.session) ->
        {:noreply, put_flash(socket, :error, "请先新建或选择一个对话")}

      true ->
        Orchestrator.send_message(socket.assigns.session.id, text)
        {:noreply, socket}
    end
  end

  def handle_event("answer_user", %{"ref" => ref_str, "text" => text}, socket) do
    text = String.trim(text)
    ref = String.to_integer(ref_str)

    if text != "" && socket.assigns.session do
      Orchestrator.reply_ask_user(socket.assigns.session.id, ref, text)
    end

    {:noreply, assign(socket, :pending_ask, nil)}
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    _ = Memory.delete_skill(id)
    {:noreply, assign(socket, :skills_sidebar, Memory.list_skills_recent())}
  end

  @impl true
  def handle_info({:user, text}, socket) do
    {:noreply, push_log(socket, {:user, text})}
  end

  def handle_info({:assistant_delta, text}, socket) do
    {:noreply, assign(socket, :draft_assistant, text)}
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

    {:noreply, socket}
  end

  def handle_info({:tool_start, name, args}, socket) do
    {:noreply, push_log(socket, {:tool_start, name, args})}
  end

  def handle_info({:tool_done, id, text}, socket) do
    {:noreply, push_log(socket, {:tool_done, id, text})}
  end

  def handle_info({:ask_user, ref, question}, socket) do
    {:noreply, assign(socket, pending_ask: %{ref: ref, question: question})}
  end

  def handle_info({:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, inspect(reason))}
  end

  def handle_info({:skill_saved, _title}, socket) do
    {:noreply, assign(socket, :skills_sidebar, Memory.list_skills_recent())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp push_log(socket, entry) do
    assign(socket, :log, socket.assigns.log ++ [entry])
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
    <div class="flex h-dvh flex-col bg-base-200 text-base-content overflow-hidden">
      <Layouts.flash_group flash={@flash} />

      <div class="flex flex-1 min-h-0 relative">
        <%!-- Mobile sidebar overlay --%>
        <div
          :if={@sidebar_open}
          class="fixed inset-0 z-40 bg-black/50 lg:hidden"
          phx-click="toggle_sidebar"
        >
        </div>

        <%!-- Sidebar --%>
        <aside class={[
          "fixed lg:static inset-y-0 left-0 z-50 flex w-[min(18rem,85vw)] flex-col border-r border-base-300 bg-base-100 transition-transform duration-200 lg:translate-x-0",
          if(@sidebar_open, do: "translate-x-0", else: "-translate-x-full")
        ]}>
          <div class="flex h-14 items-center gap-2 border-b border-base-300 px-3 shrink-0">
            <span class="font-semibold tracking-tight">FluxClaw</span>
            <span class="text-xs text-base-content/50 hidden sm:inline">OTP · LiveView</span>
          </div>

          <div class="p-2 border-b border-base-300 space-y-2 shrink-0">
            <form phx-submit="new_chat" class="flex gap-1">
              <input
                type="text"
                name="title"
                placeholder="新对话标题"
                class="input input-bordered input-sm flex-1 text-sm"
              />
              <button type="submit" class="btn btn-primary btn-sm">新建</button>
            </form>
            <button type="button" phx-click="new_chat" class="btn btn-ghost btn-sm w-full">
              快速新建对话
            </button>
          </div>

          <nav class="flex-1 overflow-y-auto p-2 space-y-0.5 min-h-0">
            <%= for s <- @sessions do %>
              <.link
                patch={~p"/chat/#{s.id}"}
                class={[
                  "flex flex-col rounded-lg px-3 py-2 text-sm transition-colors",
                  @session && @session.id == s.id && "bg-base-300 font-medium",
                  (!@session || @session.id != s.id) && "hover:bg-base-200"
                ]}
              >
                <span class="truncate">{s.title}</span>
                <span class="text-xs text-base-content/50">
                  {Calendar.strftime(s.inserted_at, "%m-%d %H:%M")}
                </span>
              </.link>
            <% end %>
            <%= if @sessions == [] do %>
              <p class="text-xs text-base-content/50 px-2 py-4">暂无历史对话</p>
            <% end %>
          </nav>

          <div class="border-t border-base-300 p-2 shrink-0 max-h-40 overflow-y-auto text-xs">
            <button
              type="button"
              phx-click="toggle_skills_panel"
              class="flex w-full items-center justify-between font-medium text-base-content/80 py-1"
            >
              <span>技能库 (L3)</span>
              <span>{if(@skills_panel_open, do: "−", else: "+")}</span>
            </button>
            <%= if @skills_panel_open do %>
              <p class="text-base-content/40 mb-1">进化门禁与 proposal 合并策略见 README 路线图。</p>
              <%= for sk <- @skills_sidebar do %>
                <div class="flex items-start justify-between gap-1 py-1 border-b border-base-200 last:border-0">
                  <span class="truncate flex-1" title={sk.title}>{sk.title}</span>
                  <button
                    type="button"
                    phx-click="delete_skill"
                    phx-value-id={sk.id}
                    class="btn btn-ghost btn-xs text-error shrink-0"
                  >
                    删
                  </button>
                </div>
              <% end %>
              <%= if @skills_sidebar == [] do %>
                <p class="text-base-content/40">尚无技能记录</p>
              <% end %>
            <% end %>
          </div>
        </aside>

        <%!-- Main column --%>
        <main class="flex flex-1 flex-col min-w-0 min-h-0 bg-base-100">
          <header class="flex h-14 items-center gap-2 border-b border-base-300 px-3 shrink-0">
            <button
              type="button"
              phx-click="toggle_sidebar"
              class="btn btn-ghost btn-square btn-sm lg:hidden"
              aria-label="打开菜单"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
            <div class="flex-1 min-w-0">
              <h1 class="text-base font-semibold truncate">
                {(@session && @session.title) || "选择或新建对话"}
              </h1>
              <p class="text-xs text-base-content/50 truncate hidden sm:block">
                每会话独立 AgentWorker · PubSub 流式推送（对齐 idea/ 设计）
              </p>
            </div>
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm hidden sm:inline-flex">首页</.link>
          </header>

          <%= if @session do %>
            <%= if @checkpoints != [] do %>
              <div class="shrink-0 border-b border-base-200 bg-base-200/50 px-3 py-2 text-xs max-h-24 overflow-y-auto">
                <span class="font-medium text-base-content/70">工作检查点</span>
                <ul class="mt-1 space-y-0.5">
                  <%= for c <- Enum.take(@checkpoints, 6) do %>
                    <li class="truncate text-base-content/60">
                      {c.label || "checkpoint"} · {Calendar.strftime(c.inserted_at, "%H:%M:%S")}
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <div
              id="chat-scroll"
              phx-hook="ChatScroll"
              class="flex-1 overflow-y-auto px-3 py-4 space-y-4 scroll-smooth"
            >
              <%= for entry <- @log do %>
                <.chat_bubble entry={entry} />
              <% end %>

              <%= if @draft_assistant && @draft_assistant != "" do %>
                <div class="flex justify-start">
                  <div class="chat-md max-w-[min(48rem,92%)] rounded-2xl bg-base-200 px-4 py-3 border border-base-300">
                    <div class="flex items-center gap-2 text-xs text-base-content/50 mb-2">
                      <span class="inline-block size-2 rounded-full bg-primary animate-pulse"></span>
                      正在生成…
                    </div>
                    <div class="chat-md">{raw(md_html(@draft_assistant))}</div>
                  </div>
                </div>
              <% end %>
            </div>

            <%= if @pending_ask do %>
              <div class="shrink-0 border-t border-warning/40 bg-warning/10 px-4 py-3">
                <p class="text-sm font-medium text-warning-content">需要你的确认</p>
                <p class="text-sm mt-1 whitespace-pre-wrap text-base-content/90">
                  {@pending_ask.question}
                </p>
                <form phx-submit="answer_user" class="mt-3 flex flex-col sm:flex-row gap-2">
                  <input type="hidden" name="ref" value={@pending_ask.ref} />
                  <textarea
                    name="text"
                    rows="2"
                    class="textarea textarea-bordered flex-1 text-sm min-h-[2.5rem]"
                    placeholder="输入回复…"
                  ></textarea>
                  <button type="submit" class="btn btn-warning shrink-0">提交回复</button>
                </form>
              </div>
            <% end %>

            <div class="shrink-0 border-t border-base-300 p-3 bg-base-100">
              <form phx-submit="send" class="mx-auto flex max-w-4xl gap-2 items-end">
                <div class="flex-1 relative">
                  <textarea
                    id="chat-composer"
                    name="text"
                    rows="1"
                    phx-hook="ChatComposer"
                    class="textarea textarea-bordered w-full min-h-[2.75rem] max-h-[12rem] resize-none pr-12 text-[15px] leading-relaxed"
                    placeholder="给 FluxClaw 发消息… (⌘/Ctrl+Enter 发送)"
                    autocomplete="off"
                  ></textarea>
                </div>
                <button type="submit" class="btn btn-primary shrink-0 h-11 px-6">发送</button>
              </form>
              <p class="text-center text-xs text-base-content/40 mt-2 hidden sm:block">
                工具调用与记忆分层参考 GenericAgent / CuteClaw 思路；指标见 /dev/dashboard
              </p>
            </div>
          <% else %>
            <div class="flex flex-1 flex-col items-center justify-center p-8 text-center text-base-content/60">
              <p class="text-lg mb-2">开始一段对话</p>
              <p class="text-sm max-w-md mb-6">
                左侧新建或选择会话。每个会话对应独立 OTP 进程与沙箱目录，流式回复通过 PubSub 推送到本页。
              </p>
              <button type="button" phx-click="new_chat" class="btn btn-primary">
                新建对话
              </button>
            </div>
          <% end %>
        </main>
      </div>
    </div>
    """
  end

  attr :entry, :any, required: true

  def chat_bubble(assigns) do
    ~H"""
    <%= case @entry do %>
      <% {:history, "user", content} -> %>
        <.bubble_user content={content} />
      <% {:history, "assistant", content} -> %>
        <.bubble_assistant content={content} />
      <% {:history, role, content} -> %>
        <.bubble_system role={role} content={content} />
      <% {:user, content} -> %>
        <.bubble_user content={content} />
      <% {:assistant, content} -> %>
        <.bubble_assistant content={content} />
      <% {:tool_start, name, args} -> %>
        <div class="flex justify-center">
          <div class="rounded-lg bg-base-200/80 border border-base-300 px-3 py-2 text-xs text-base-content/60 max-w-[min(40rem,95%)]">
            <span class="font-mono text-primary">工具</span> {name}
            <pre class="mt-1 overflow-x-auto text-[11px]">{inspect(args, pretty: true)}</pre>
          </div>
        </div>
      <% {:tool_done, id, text} -> %>
        <div class="flex justify-center">
          <div class="rounded-lg bg-base-200/50 border border-dashed border-base-300 px-3 py-2 text-xs max-w-[min(40rem,95%)]">
            <span class="text-base-content/50">结果</span> <span class="font-mono">{id}</span>
            <pre class="mt-1 whitespace-pre-wrap text-[11px] text-base-content/70">{text}</pre>
          </div>
        </div>
    <% end %>
    """
  end

  attr :content, :string, required: true

  def bubble_user(assigns) do
    ~H"""
    <div class="flex justify-end">
      <div class="max-w-[min(40rem,85%)] rounded-2xl rounded-br-md bg-primary text-primary-content px-4 py-2.5 text-[15px] leading-relaxed shadow-sm">
        <div class="whitespace-pre-wrap">{@content}</div>
      </div>
    </div>
    """
  end

  attr :content, :string, required: true

  def bubble_assistant(assigns) do
    html = md_html(assigns.content)
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="flex justify-start">
      <div class="chat-md max-w-[min(48rem,92%)] rounded-2xl rounded-bl-md bg-base-200 px-4 py-3 border border-base-300 text-[15px]">
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
      <div class="chat-md max-w-[min(48rem,92%)] rounded-xl bg-base-200/60 px-3 py-2 border border-base-200 text-sm opacity-90">
        <span class="text-xs text-base-content/40">{@role}</span>
        <div>{raw(@html)}</div>
      </div>
    </div>
    """
  end
end
