defmodule FluxClawWeb.WorkbenchComponents do
  @moduledoc "Shared surfaces for the browser and desktop CoWork workspace."
  use FluxClawWeb, :html

  def templates do
    [
      %{
        id: "document",
        icon: "hero-document-text",
        title: "文档与写作",
        subtitle: "让想法成为清晰的表达",
        tag: "写作",
        color: "mint",
        prompt: "帮我起草一份工作文档。请先确认读者、目标和已有资料，再整理结构、撰写正文，并保存为 Markdown 文件："
      },
      %{
        id: "research",
        icon: "hero-globe-alt",
        title: "调研与分析",
        subtitle: "搜集资料，找到关键洞察",
        tag: "研究",
        color: "blue",
        prompt: "搜索这个主题的可靠资料，交叉核实并注明来源，整理成可交付的研究报告："
      },
      %{
        id: "data",
        icon: "hero-chart-bar",
        title: "数据与表格",
        subtitle: "从繁杂数据中发现答案",
        tag: "分析",
        color: "amber",
        prompt: "请分析我提供的数据或 CSV 文件，先核实字段与数据质量，再计算关键指标，整理结论并保存分析结果："
      },
      %{
        id: "organize",
        icon: "hero-clipboard-document-check",
        title: "规划与整理",
        subtitle: "理清重点，让下一步更明确",
        tag: "规划",
        color: "violet",
        prompt: "把下面的内容整理成清晰的行动清单，标出负责人、优先级与待确认事项，并保存为 Markdown 文件："
      },
      %{
        id: "build",
        icon: "hero-code-bracket",
        title: "代码与构建",
        subtitle: "从一个需求到可运行的实现",
        tag: "开发",
        color: "blue",
        prompt: "请帮我实现这个功能，先阅读项目并制定计划，再编写代码、运行验证，说明修改和测试结果："
      },
      %{
        id: "presentation",
        icon: "hero-presentation-chart-line",
        title: "汇报与演示",
        subtitle: "把工作成果讲得更有说服力",
        tag: "汇报",
        color: "rose",
        prompt: "帮我准备一份汇报的内容大纲。先明确听众和核心结论，再逐页组织标题、论据与讲稿，保存为 Markdown 文件："
      }
    ]
  end

  attr :compact, :boolean, default: false

  def brand(assigns) do
    ~H"""
    <span class="cw-brand-mark" aria-hidden="true">F<span></span></span>
    <span :if={!@compact} class="cw-brand-name">FluxClaw<span>CoWork</span></span>
    """
  end

  attr :project, :any, default: nil

  def welcome(assigns) do
    ~H"""
    <section id="workbench-welcome" class="wb-welcome">
      <div class="cw-welcome-top">
        <span class="cw-pill"><span class="wb-status-dot"></span> 你的 AI 工作搭档</span><span class="cw-welcome-note">THINK. CREATE. TOGETHER.</span>
      </div>
      <div class="cw-greeting-mark"><.brand compact /></div>
      <h2>把想法交给我，<br /><span>把时间留给你。</span></h2>
      <p>写一份文档、研究一个问题，或构建下一个产品。<br class="hidden sm:block" />从第一步到最后一公里，FluxClaw 和你一起完成。</p>
      <div class="cw-section-heading">
        <h3>从这里开始</h3>
        <span>一个工作台，无限种可能</span>
      </div>
      <div class="wb-examples">
        <button
          :for={task <- Enum.take(templates(), 4)}
          id={"example-#{task.id}"}
          type="button"
          phx-click="fill_example"
          phx-value-text={task.prompt}
          class="wb-example"
        >
          <span class={["cw-template-icon", "cw-tone-#{task.color}"]}>
            <.icon name={task.icon} class="size-5" />
          </span>
          <strong>{task.title}</strong><span class="cw-card-description">{task.subtitle}</span>
          <.icon name="hero-arrow-up-right" class="cw-card-arrow size-3.5" />
        </button>
      </div>
      <div class="cw-starter-row">
        <span>也可以试试</span><button
          id="example-build"
          phx-click="fill_example"
          phx-value-text={Enum.at(templates(), 4).prompt}
        ><.icon name="hero-code-bracket" class="size-3.5" />开发一个功能</button><button
          id="example-presentation"
          phx-click="fill_example"
          phx-value-text={Enum.at(templates(), 5).prompt}
        ><.icon name="hero-presentation-chart-line" class="size-3.5" />准备一份汇报</button>
      </div>
      <div :if={@project} class="cw-context-note">
        <.icon name="hero-folder" class="size-3.5" />当前项目
        <strong>{@project.title}</strong><span>· 对话与经验将在这里积累</span>
      </div>
    </section>
    """
  end

  attr :projects, :any, required: true
  attr :count, :integer, required: true

  def projects_page(assigns) do
    ~H"""
    <section id="projects-page" class="cw-page">
      <div class="cw-page-heading">
        <div>
          <div class="wb-eyebrow">YOUR WORK, CONNECTED</div>
          <h2>项目空间<span>{@count}</span></h2>
          <p>把相关对话、文件与经验放在一起，让每次工作都有上下文。</p>
        </div>
        <button id="create-project" phx-click="new_project" class="wb-primary">
          <.icon name="hero-plus" class="size-4" />新建项目
        </button>
      </div>
      <div id="workspace-projects" phx-update="stream" class="cw-project-grid">
        <div id="projects-empty" class="cw-empty hidden only:flex">
          <.icon name="hero-folder-plus" class="size-10" />
          <h3>为下一件大事，创建一个空间</h3>
          <p>从一个项目开始，持续积累你的工作成果。</p>
          <button id="first-project" phx-click="new_project" class="wb-primary">创建第一个项目</button>
        </div>
        <article :for={{dom_id, project} <- @projects} id={dom_id} class="cw-project-card">
          <div class="cw-project-card-top">
            <span class="cw-template-icon cw-tone-mint">
              <.icon name="hero-folder" class="size-6" />
            </span>
            <button
              id={"project-card-menu-#{project.id}"}
              phx-hook="SidebarContextMenu"
              data-menu-type="project"
              data-menu-id={project.id}
              class="cw-icon-button"
              aria-label={"管理项目 #{project.title}"}
            >
              <.icon name="hero-ellipsis-horizontal" class="size-5" />
            </button>
          </div>
          <.link patch={~p"/p/#{project.id}"} class="cw-project-link">
            <h3>{project.title}</h3>
            <p>对话 · 文件 · 技能 · 项目记忆</p>
            <div>
              <span>创建于 {Calendar.strftime(project.inserted_at, "%Y.%m.%d")}</span>
              <.icon name="hero-arrow-up-right" class="size-4" />
            </div>
          </.link>
        </article>
      </div>
      <div class="cw-page-tip">
        <.icon name="hero-light-bulb" class="size-5" />
        <div>
          <strong>越协作，越默契</strong>
          <p>项目让相关工作保持连续。将常用的方法保存为技能，下次直接复用。</p>
        </div>
      </div>
    </section>
    """
  end

  attr :skills, :any, required: true
  attr :count, :integer, required: true
  attr :filter, :string, default: "all"

  def skills_page(assigns) do
    assigns =
      assign(
        assigns,
        :templates,
        Enum.filter(templates(), &(assigns.filter == "all" || &1.tag == assigns.filter))
      )

    ~H"""
    <section id="skills-page" class="cw-page">
      <div class="cw-page-heading">
        <div>
          <div class="wb-eyebrow">LESS REPETITION, MORE CREATION</div>
          <h2>技能与灵感</h2>
          <p>从一个好用的起点开始，把重复的工作交给你的 AI 搭档。</p>
        </div>
        <button id="library-import-skill" phx-click="open_skill_import" class="wb-secondary">
          <.icon name="hero-arrow-down-tray" class="size-4" />导入技能
        </button>
      </div>
      <nav class="cw-filter-tabs" aria-label="场景筛选">
        <button
          :for={filter <- ["all", "写作", "研究", "分析", "规划", "开发", "汇报"]}
          id={"skill-filter-#{filter}"}
          phx-click="filter_templates"
          phx-value-filter={filter}
          class={[@filter == filter && "is-active"]}
        >
          {if(filter == "all", do: "全部场景", else: filter)}
        </button>
      </nav>
      <div class="cw-library-grid">
        <button
          :for={task <- @templates}
          id={"template-#{task.id}"}
          phx-click="use_template"
          phx-value-id={task.id}
          class="cw-library-card"
        >
          <div>
            <span class={["cw-template-icon", "cw-tone-#{task.color}"]}>
              <.icon name={task.icon} class="size-6" />
            </span>
            <span class="cw-tag">{task.tag}</span>
          </div>
          <h3>{task.title}</h3>
          <p>{task.subtitle}</p>
          <footer><span>任务起点 · 点击补充需求</span> <.icon name="hero-arrow-right" class="size-4" /></footer>
        </button>
      </div>
      <div class="cw-section-heading cw-saved-heading">
        <h3>项目专属技能 <span>{@count}</span></h3>
        <button id="library-new-skill" phx-click="open_skill_editor_new">
          <.icon name="hero-plus" class="size-4" />创建技能
        </button>
      </div>
      <div id="workspace-skills" phx-update="stream" class="cw-library-grid">
        <div id="skills-empty" class="cw-empty cw-empty-small hidden only:flex">
          <.icon name="hero-sparkles" class="size-7" />
          <div>
            <h3>把好方法留下来</h3>
            <p>创建或导入技能，让项目里的成功经验可以复用。</p>
          </div>
        </div>
        <article :for={{dom_id, skill} <- @skills} id={dom_id} class="cw-saved-skill">
          <span class="cw-template-icon cw-tone-mint"><.icon name="hero-bolt" class="size-5" /></span>
          <div>
            <h3>{skill.title}</h3>
            <p>{skill.keywords || "项目技能"}</p>
          </div>
          <button
            id={"library-skill-menu-#{skill.id}"}
            phx-hook="SidebarContextMenu"
            data-menu-type="skill"
            data-menu-id={skill.id}
            class="cw-icon-button"
            aria-label="管理技能"
          >
            <.icon name="hero-ellipsis-horizontal" class="size-5" />
          </button>
        </article>
      </div>
    </section>
    """
  end

  attr :query, :string, default: ""
  attr :projects, :list, required: true
  attr :sessions, :list, required: true

  def command_palette(assigns) do
    query = String.downcase(String.trim(assigns.query))

    commands = [
      {"新建对话", "hero-plus", "new_chat", "N"},
      {"新建项目", "hero-folder-plus", "new_project", ""},
      {"模型与设置", "hero-cog-6-tooth", "toggle_settings", ","},
      {"查看文件", "hero-document-duplicate", "palette_files", ""}
    ]

    assigns =
      assigns
      |> assign(:form, to_form(%{"query" => assigns.query}))
      |> assign(
        :commands,
        Enum.filter(commands, fn {label, _, _, _} ->
          String.contains?(String.downcase(label), query)
        end)
      )
      |> assign(
        :matches_projects,
        Enum.filter(assigns.projects, &String.contains?(String.downcase(&1.title), query))
      )
      |> assign(
        :matches_sessions,
        Enum.filter(assigns.sessions, &String.contains?(String.downcase(&1.title), query))
      )

    ~H"""
    <div
      id="command-palette"
      class="cw-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="command-title"
    >
      <div class="cw-modal-scrim" phx-click="close_palette"></div>
      <div class="cw-command-dialog">
        <.form
          for={@form}
          id="command-search-form"
          phx-change="search_commands"
          phx-submit="search_commands"
        >
          <.icon name="hero-magnifying-glass" class="size-5" />
          <label
            id="command-title"
            for="command-search"
            class="sr-only"
          >
            搜索命令、项目或对话
          </label>
          <.input
            field={@form[:query]}
            id="command-search"
            class="cw-command-input"
            placeholder="搜索命令、项目或对话…"
            autocomplete="off"
            phx-debounce="100"
            phx-mounted={JS.focus()}
          />
          <button type="button" phx-click="close_palette" aria-label="关闭命令面板">
            <kbd>ESC</kbd>
          </button>
        </.form>
        <div id="command-results" class="cw-command-results">
          <p :if={@commands != []} class="cw-command-label">快捷操作</p>
          <button
            :for={{label, icon, event, key} <- @commands}
            id={"command-#{event}"}
            phx-click={JS.push("close_palette") |> JS.push(event)}
            class="cw-command-result"
          >
            <.icon name={icon} class="size-4" />{label}<kbd :if={key != ""}>{key}</kbd>
          </button>
          <p :if={@matches_projects != []} class="cw-command-label">项目</p>
          <.link
            :for={project <- Enum.take(@matches_projects, 8)}
            patch={~p"/p/#{project.id}"}
            class="cw-command-result"
          >
            <.icon name="hero-folder" class="size-4" />{project.title}
          </.link>
          <p :if={@matches_sessions != []} class="cw-command-label">当前项目的对话</p>
          <.link
            :for={session <- Enum.take(@matches_sessions, 8)}
            patch={~p"/chat/#{session.id}"}
            class="cw-command-result"
          >
            <.icon name="hero-chat-bubble-left" class="size-4" />{session.title}
          </.link>
          <p
            :if={@commands == [] && @matches_projects == [] && @matches_sessions == []}
            id="command-empty"
            class="cw-command-empty"
          >
            没有找到相关结果，试试其他关键词。
          </p>
        </div>
        <footer>
          <span><kbd>↑</kbd><kbd>↓</kbd>选择 <kbd>↵</kbd>打开</span><span>FluxClaw CoWork</span>
        </footer>
      </div>
    </div>
    """
  end

  attr :values, :map, required: true
  attr :tab, :string, required: true
  attr :model_options, :list, default: []
  attr :key_configured, :boolean, default: false
  slot :integrations

  def settings(assigns) do
    assigns = assign(assigns, :form, to_form(assigns.values))

    ~H"""
    <div
      id="settings-center"
      class="cw-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-title"
    >
      <div class="cw-modal-scrim" phx-click="toggle_settings"></div>
      <section class="cw-settings-dialog">
        <header>
          <div>
            <span class="cw-template-icon cw-tone-mint">
              <.icon name="hero-cog-6-tooth" class="size-5" />
            </span>
            <h2 id="settings-title">设置中心</h2>
            <span>让工作台更适合你</span>
          </div>
          <button
            id="close-settings"
            phx-click="toggle_settings"
            class="cw-icon-button"
            aria-label="关闭设置"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>
        <div class="cw-settings-body">
          <nav aria-label="设置分类">
            <button
              :for={
                {id, label, icon} <- [
                  {"model", "模型与 API", "hero-cube-transparent"},
                  {"tools", "工具与执行", "hero-command-line"},
                  {"integrations", "工具集成", "hero-puzzle-piece"},
                  {"memory", "记忆与技能", "hero-circle-stack"},
                  {"appearance", "外观", "hero-swatch"}
                ]
              }
              id={"settings-tab-#{id}"}
              phx-click="settings_tab"
              phx-value-tab={id}
              class={[@tab == id && "is-active"]}
            >
              <.icon name={icon} class="size-4" />{label}
            </button>
            <div class="cw-settings-about">
              <.brand />
              <p>你的通用 AI 工作搭档</p>
              <span>Web & Desktop · v{Application.spec(:flux_claw, :vsn)}</span>
            </div>
          </nav>
          <.form
            for={@form}
            id="settings-form"
            phx-change="validate_settings"
            phx-submit="save_settings"
            class="cw-settings-form"
            hidden={@tab == "integrations"}
          >
            <div class="cw-settings-content">
              <section id="settings-model-section" hidden={@tab != "model"}>
                <h3>模型与 API</h3>
                <p class="cw-setting-description">连接你偏好的模型，开始对话与协作。</p>
                <.input
                  field={@form[:base_url]}
                  id="settings-base-url"
                  label="API 服务地址"
                  placeholder="https://api.openai.com/v1"
                  class="cw-setting-input"
                />
                <.input
                  field={@form[:api_key]}
                  id="settings-api-key"
                  type="password"
                  label="API Key"
                  placeholder={if(@key_configured, do: "已配置 · 留空保留现有密钥", else: "输入 API Key")}
                  autocomplete="new-password"
                  class="cw-setting-input"
                />
                <div class="cw-setting-inline">
                  <label for="settings-model-text">默认模型</label><button
                    id="refresh-models"
                    type="button"
                    phx-click="refresh_models"
                  >刷新模型列表 <.icon name="hero-arrow-path" class="size-3" /></button>
                </div>
                <.input
                  :if={@model_options != []}
                  name="picked"
                  id="settings-model-pick"
                  type="select"
                  value={@values["model"]}
                  options={@model_options}
                  prompt="从已连接服务选择"
                  phx-change="settings_pick_model"
                  class="cw-setting-input"
                />
                <.input
                  field={@form[:model]}
                  id="settings-model-text"
                  placeholder="输入模型 ID"
                  class="cw-setting-input"
                />
                <details class="cw-advanced">
                  <summary>高级采样参数</summary>
                  <div class="grid grid-cols-3 gap-3">
                    <.input
                      :for={key <- ["temperature", "top_p", "top_k"]}
                      name={key}
                      id={"settings-#{key}"}
                      value={@values[key]}
                      label={key}
                      class="cw-setting-input"
                      placeholder="默认"
                    />
                  </div>
                </details>
              </section>
              <section id="settings-tools-section" hidden={@tab != "tools"}>
                <h3>工具与执行</h3>
                <p class="cw-setting-description">控制任务执行深度与工作文件的存储位置。</p>
                <.input
                  field={@form[:max_steps]}
                  id="settings-max-steps"
                  type="number"
                  min="-1"
                  label="Agent 最大执行轮次"
                  class="cw-setting-input"
                />
                <p class="cw-field-help">0 为仅对话，-1 为不限轮次，其余数值为工具循环上限。</p>
                <.input
                  field={@form[:cache_root]}
                  id="settings-cache-root"
                  label="工作数据目录"
                  class="cw-setting-input"
                  placeholder="./fluxclaw/cache"
                /><.input
                  field={@form[:history_root]}
                  id="settings-history-root"
                  label="对话记录目录"
                  class="cw-setting-input"
                />
                <div class="cw-settings-info">
                  <.icon name="hero-information-circle" class="size-5" />
                  <p>联网检索与插件服务在本设置中心的「工具集成」中配置。</p>
                </div>
              </section>
              <section id="settings-memory-section" hidden={@tab != "memory"}>
                <h3>记忆与技能</h3>
                <p class="cw-setting-description">把工作经验转变为下一次协作的起点。</p>
                <.input
                  name="self_evolve"
                  id="settings-self-evolve"
                  type="checkbox"
                  value="true"
                  checked={@values["self_evolve"] == "true"}
                  label="自动记录工具执行经验"
                /><.input
                  name="crystallize_skills"
                  id="settings-crystallize"
                  type="checkbox"
                  value="true"
                  checked={@values["crystallize_skills"] == "true"}
                  label="从工作经验中提炼技能"
                /><.input
                  field={@form[:crystallize_mode]}
                  id="settings-crystallize-mode"
                  type="select"
                  label="技能保存方式"
                  options={[{"自动保存", "auto"}, {"确认后保存", "confirm"}]}
                  class="cw-setting-input"
                /><.input
                  field={@form[:memory_root]}
                  id="settings-memory-root"
                  label="记忆文档目录"
                  class="cw-setting-input"
                /><.input
                  field={@form[:external_skills]}
                  id="settings-external-skills"
                  label="外部技能目录"
                  class="cw-setting-input"
                /><.input
                  field={@form[:internal_skills]}
                  id="settings-internal-skills"
                  label="项目技能目录"
                  class="cw-setting-input"
                />
              </section>
              <section id="settings-appearance-section" hidden={@tab != "appearance"}>
                <h3>外观</h3>
                <p class="cw-setting-description">让专注的每一刻，都舒适自然。</p>
                <div class="cw-theme-options">
                  <button
                    :for={
                      {theme, label, icon} <- [
                        {"dark", "深空石墨", "hero-moon"},
                        {"light", "清晨薄荷", "hero-sun"},
                        {"system", "跟随系统", "hero-computer-desktop"}
                      ]
                    }
                    id={"theme-option-#{theme}"}
                    type="button"
                    data-theme-choice={theme}
                    phx-click={JS.dispatch("fluxclaw:set-theme", detail: %{theme: theme})}
                  >
                    <span class={["cw-theme-preview", "cw-preview-#{theme}"]}>
                      <i></i><i></i><i></i>
                    </span>
                    <.icon name={icon} class="size-4" />{label}
                  </button>
                </div>
                <div class="cw-settings-info">
                  <.icon name="hero-check-circle" class="size-5" />
                  <p>外观自动保存在当前设备，桌面与网页共用同一套工作台体验。</p>
                </div>
              </section>
            </div>
            <footer>
              <span>配置保存在本地</span><button
                id="cancel-settings"
                type="button"
                phx-click="toggle_settings"
                class="wb-secondary"
              >取消</button><button id="save-settings" type="submit" class="wb-primary">保存设置</button>
            </footer>
          </.form>
          <div
            :if={@tab == "integrations"}
            id="settings-integrations-section"
            class="cw-settings-integrations"
          >
            {render_slot(@integrations)}
          </div>
        </div>
      </section>
    </div>
    """
  end
end
