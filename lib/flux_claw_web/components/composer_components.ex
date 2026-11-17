defmodule FluxClawWeb.ComposerComponents do
  use FluxClawWeb, :html
  alias FluxClaw.LLM.RunSettings

  attr :form, :any, required: true
  attr :uploads, :any, required: true
  attr :staged_attachments, :list, default: []
  attr :agent_busy, :boolean, required: true
  attr :locked, :boolean, required: true
  attr :session_id, :any, default: nil
  attr :project_id, :any, default: nil
  attr :settings, :map, required: true
  attr :run, :map, required: true
  attr :picker_open, :boolean, required: true
  attr :model_choices, :any, required: true
  attr :model_loading, :boolean, required: true
  attr :model_error, :any, required: true
  attr :model_query, :string, required: true
  attr :model_search_form, :any, required: true
  attr :visible, :boolean, default: true

  def composer(assigns) do
    assigns =
      assign(
        assigns,
        :upload_blocked,
        Enum.any?(assigns.uploads.attachments.entries, &(!&1.done?)) ||
          Enum.any?(
            assigns.uploads.attachments.entries,
            &(upload_errors(assigns.uploads.attachments, &1) != [])
          ) ||
          length(assigns.uploads.attachments.entries) + length(assigns.staged_attachments) > 5 ||
          upload_errors(assigns.uploads.attachments) != []
      )

    ~H"""
    <div id="composer-area" class={["wb-composer-area cw-compose-area", !@visible && "hidden"]}>
      <div :if={@settings["api_key"] in [nil, ""]} id="model-setup-notice" class="wb-model-notice">
        连接你的模型，开始处理工作。<button type="button" id="open-model-settings" phx-click="toggle_settings">配置服务 <.icon
            name="hero-arrow-up-right"
            class="size-3"
          /></button>
      </div>
      <div :if={@locked && !@agent_busy} class="wb-composer-hint">先处理上方的确认事项 · 草稿已保留</div>
      <section
        :if={@picker_open}
        id="composer-model-panel"
        class="cw-model-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="model-panel-title"
        phx-click-away="close_model_picker"
      >
        <div class="cw-model-heading">
          <div>
            <span class="cw-panel-eyebrow">为这个任务选择</span>
            <h2 id="model-panel-title">模型与思考方式</h2>
          </div>
          <button
            id="close-model-picker"
            type="button"
            phx-click="close_model_picker"
            aria-label="关闭模型选择"
            class="cw-icon-button"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <.form
          for={@model_search_form}
          id="composer-model-search"
          phx-change="search_composer_models"
          phx-submit="use_custom_model"
          class="cw-model-search"
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
          <.input
            field={@model_search_form[:query]}
            id="composer-model-query"
            placeholder="搜索模型，或输入模型 ID"
            autocomplete="off"
            class="cw-model-search-input"
            phx-debounce="150"
          />
          <button
            id="refresh-composer-models"
            type="button"
            phx-click="refresh_composer_models"
            disabled={@model_loading}
            class="cw-icon-button"
            title="从服务获取模型"
            aria-label="刷新模型列表"
          >
            <.icon name="hero-arrow-path" class={["size-4", @model_loading && "animate-spin"]} />
          </button>
        </.form>
        <p :if={@model_loading} id="composer-model-loading" class="cw-model-note" role="status">
          正在获取服务提供的模型…
        </p>
        <p :if={@model_error} id="composer-model-error" class="cw-model-note" role="status">
          {@model_error}
        </p>
        <div
          id="composer-model-list"
          phx-update="stream"
          class="cw-model-list"
          role="group"
          aria-label="可用模型"
        >
          <div id="composer-model-empty" class="hidden only:block cw-model-note">
            没有匹配的模型。可以输入服务支持的完整模型 ID。
          </div>
          <button
            :for={{id, choice} <- @model_choices}
            id={id}
            type="button"
            class={["cw-model-choice", @run.model == choice.model && "is-selected"]}
            phx-click="select_composer_model"
            phx-value-model={choice.model}
            aria-pressed={to_string(@run.model == choice.model)}
            disabled={@locked}
          >
            <span class="cw-model-symbol"><.icon name="hero-cube-transparent" class="size-4" /></span>
            <span class="cw-model-choice-name">
              {choice.model}<small>{if(choice.model == @settings["model"], do: "服务默认模型", else: "用于当前对话")}</small>
            </span>
            <.icon :if={@run.model == choice.model} name="hero-check" class="size-4 cw-model-check" />
          </button>
        </div>
        <button
          :if={String.trim(@model_query) != ""}
          id="use-custom-model"
          type="button"
          phx-click="use_custom_model"
          disabled={@locked}
          class="cw-custom-model"
        >
          <.icon name="hero-plus" class="size-4" /><span>使用模型 ID：{String.trim(@model_query)}</span>
        </button>
        <div class="cw-reasoning-section">
          <div class="cw-reasoning-title">
            <.icon name="hero-sparkles" class="size-4" /><span>思考强度</span><span class="cw-panel-eyebrow">{RunSettings.label(@run.reasoning_effort)}</span>
          </div>
          <div class="cw-reasoning-options" role="group" aria-label="思考强度">
            <button
              :for={
                {value, name, hint} <- [
                  {"auto", "自动", "模型默认"},
                  {"low", "快速", "轻量思考"},
                  {"medium", "均衡", "日常工作"},
                  {"high", "深入", "复杂任务"}
                ]
              }
              id={"reasoning-#{value}"}
              type="button"
              phx-click="select_reasoning"
              phx-value-effort={value}
              disabled={@locked || value not in RunSettings.levels(@run.model)}
              aria-pressed={to_string(@run.reasoning_effort == value)}
              class={[@run.reasoning_effort == value && "is-selected"]}
            >
              <strong>{name}</strong><small>{hint}</small>
            </button>
          </div>
          <p class="cw-model-note">
            {if(RunSettings.levels(@run.model) == ["auto"],
              do: "这个模型使用默认思考方式。",
              else: "深入思考可能需要更多时间与用量，具体能力取决于模型服务的支持。"
            )}
          </p>
        </div>
        <footer class="cw-model-footer">
          <span>{if(@locked, do: "任务执行期间无法切换", else: "仅用于当前对话 · 自动保存")}</span><button
            id="composer-provider-settings"
            type="button"
            phx-click="toggle_settings"
          >配置模型服务 <.icon name="hero-arrow-up-right" class="size-3" /></button>
        </footer>
      </section>
      <.form
        for={@form}
        id="chat-send-form"
        phx-submit="send"
        phx-change="validate_upload"
        phx-drop-target={@uploads.attachments.ref}
        class="wb-composer cw-compose"
        data-locked={to_string(@locked)}
        data-upload-blocked={to_string(@upload_blocked)}
        data-attachment-count={length(@uploads.attachments.entries) + length(@staged_attachments)}
      >
        <div
          :if={@uploads.attachments.entries != [] || @staged_attachments != []}
          id="composer-attachments"
          class="cw-attachments"
          aria-label="待发送附件"
          aria-live="polite"
        >
          <article
            :for={file <- @staged_attachments}
            id={"staged-#{Path.basename(file["path"])}"}
            class="cw-attachment"
          >
            <span class="cw-attachment-icon">
              <.icon name={file_icon(file["name"])} class="size-5" />
            </span>
            <div class="cw-attachment-info">
              <strong title={file["name"]}>{file["name"]}</strong><small>{file_size(file["size"])}<span>·</span>已就绪</small>
            </div>
            <button
              type="button"
              phx-click="cancel_staged_attachment"
              phx-value-path={file["path"]}
              class="cw-icon-button"
              aria-label={"移除 #{file["name"]}"}
              title="移除附件"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </article>
          <article
            :for={entry <- @uploads.attachments.entries}
            id={"attachment-#{entry.ref}"}
            class={["cw-attachment", upload_errors(@uploads.attachments, entry) != [] && "has-error"]}
          >
            <span class="cw-attachment-icon">
              <.icon name={file_icon(entry.client_name)} class="size-5" />
            </span>
            <div class="cw-attachment-info">
              <strong title={entry.client_name}>{entry.client_name}</strong><small>{file_size(entry.client_size)}<span>·</span>{if(entry.done?, do: "已就绪", else: "上传中 #{entry.progress}%")}</small>
              <progress
                :if={!entry.done? && upload_errors(@uploads.attachments, entry) == []}
                value={entry.progress}
                max="100"
                aria-label={"#{entry.client_name} 上传进度"}
              >
              </progress>
              <span :for={error <- upload_errors(@uploads.attachments, entry)} class="cw-upload-error">
                {upload_error(error)}
              </span>
            </div>
            <button
              id={"remove-attachment-#{entry.ref}"}
              type="button"
              phx-click="cancel_attachment"
              phx-value-ref={entry.ref}
              class="cw-icon-button"
              aria-label={"移除 #{entry.client_name}"}
              title="移除附件"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </article>
        </div>
        <p :for={error <- upload_errors(@uploads.attachments)} class="cw-upload-error" role="alert">
          {upload_error(error)}
        </p>
        <.input
          field={@form[:text]}
          type="textarea"
          id={"chat-composer-" <> (@session_id || @project_id || "home")}
          rows="2"
          class="wb-composer-input"
          phx-hook="ChatComposer"
          phx-update="ignore"
          data-draft-key={@session_id || @project_id || "home"}
          placeholder="描述你的任务，或添加文件一起处理…"
          aria-label="任务内容"
          autocomplete="off"
        />
        <div class="wb-composer-toolbar">
          <.live_file_input
            upload={@uploads.attachments}
            class="cw-file-input"
            tabindex="-1"
            disabled={@locked}
            aria-label="选择附件"
          />
          <button
            id="composer-attach"
            type="button"
            phx-click={JS.dispatch("click", to: "##{@uploads.attachments.ref}")}
            disabled={@locked}
            class="cw-attach-button"
            title="添加附件 · 支持拖入或粘贴，最多 5 个，每个 8 MB"
            aria-label="添加附件"
          >
            <.icon name="hero-plus" class="size-5" /><span class="cw-attach-label">附件</span>
          </button>
          <span class="cw-composer-divider"></span>
          <div
            class="cw-execution-control"
            title={
              if(@run.execution_mode == "plan",
                do: "只读资料、检索与制定计划，不运行命令或修改文件",
                else: "使用工具完成任务，可创建文件与运行命令"
              )
            }
          >
            <.icon
              name={
                if(@run.execution_mode == "plan",
                  do: "hero-clipboard-document-list",
                  else: "hero-bolt"
                )
              }
              class="size-4"
            />
            <.input
              id="execution-mode"
              type="select"
              name="mode"
              value={@run.execution_mode}
              options={[{"执行", "agent"}, {"规划", "plan"}]}
              phx-change="execution_mode"
              disabled={@locked}
              aria-label="Agent 工作模式"
              class="cw-execution-select"
            />
          </div>
          <button
            id="composer-model"
            type="button"
            phx-click="toggle_model_picker"
            class="wb-model-picker"
            aria-haspopup="dialog"
            aria-expanded={to_string(@picker_open)}
            aria-controls="composer-model-panel"
          >
            <.icon name="hero-cube-transparent" class="size-4" />
            <span class="cw-selected-model">
              {if(@run.model == "", do: "选择模型", else: @run.model)}
            </span>
            <span class="cw-effort-badge">{RunSettings.label(@run.reasoning_effort)}</span>
            <.icon name="hero-chevron-up" class="size-3" />
          </button>
          <span class="wb-composer-shortcut">Shift + Enter 换行</span>
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
            disabled={@locked || @upload_blocked}
            class="wb-send"
            aria-label="发送任务"
            title="发送任务 · Enter"
          >
            <.icon name="hero-arrow-up" class="size-5" />
          </button>
        </div>
        <div class="cw-drop-hint">
          <.icon name="hero-arrow-up-tray" class="size-6" />把文件放在这里，交给 FluxClaw
        </div>
      </.form>
      <p class="wb-composer-footnote">
        <span id="execution-mode-hint">
          {if(@run.execution_mode == "plan",
            do: "规划模式 · 读取资料与制定方案，不修改文件或执行命令",
            else: "执行模式 · 使用工具完成任务，支持文档、表格与代码"
          )}
        </span>
        <span>最多 5 个附件 · 每个 8 MB</span>
      </p>
    </div>
    """
  end

  def file_size(size) when size >= 1_000_000, do: "#{Float.round(size / 1_000_000, 1)} MB"
  def file_size(size) when size >= 1_000, do: "#{Float.round(size / 1_000, 1)} KB"
  def file_size(size), do: "#{size} B"

  defp file_icon(name) do
    case String.downcase(Path.extname(name)) do
      ext when ext in [".png", ".jpg", ".jpeg", ".webp", ".gif"] -> "hero-photo"
      ext when ext in [".csv", ".xlsx", ".xls"] -> "hero-table-cells"
      ext when ext in [".ex", ".js", ".py", ".json", ".ts", ".html"] -> "hero-code-bracket"
      _ -> "hero-document-text"
    end
  end

  defp upload_error(:too_large), do: "文件超过 8 MB，请移除后重新选择"
  defp upload_error(:too_many_files), do: "最多添加 5 个附件，请移除多余文件"
  defp upload_error(:not_accepted), do: "无法上传此类文件"
  defp upload_error(_), do: "上传失败，请移除后重试"
end
