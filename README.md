# FluxClaw

基于 **BEAM（Erlang/OTP）**、**Phoenix LiveView** 和 **Electron** 的通用 LLM Agent 工作台。在项目中开展研究、编写代码和生成文档；通过流式对话、工具活动、人工问答和文件交付追踪任务。支持暖白 / 深色主题、移动端布局与独立桌面运行。

新版操作说明见 **[工作台与原生集成](docs/workbench.md)**；桌面安装、构建和验证见 **[Electron 桌面版](docs/desktop.md)**。

本轮测试结果、安装包与验证范围见 **[交付验收](reports/validation.md)**。

架构与记忆分层说明见 **[docs/architecture.md](docs/architecture.md)**、**[docs/agent-and-memory.md](docs/agent-and-memory.md)**、**[docs/tools-and-safety.md](docs/tools-and-safety.md)**。

## 功能概要

- **路由**：`/`、`/chat`、`/chat/:session_id`、`/p/:project_id`；旧 `/agents` 重定向到 `/`。
- **OTP**：Registry + DynamicSupervisor 按会话拉起 Agent；工具沙箱按会话目录隔离。
- **LLM**：OpenAI 兼容 Chat Completions，**真实 SSE**（`stream: true`）；测试使用 Mock。
- **工具**：`file_read` / `file_write` / `file_patch` / `shell_execute` / `web_fetch` / `task_plan` / `ask_user` / `update_working_checkpoint` / `start_long_term_update`（见 `lib/flux_claw/tool.ex`）。
- **原生集成**：`agent_search` 对接 SciPhi AgentSearch 自托管或托管契约，返回可引用来源；`harness2_optimize` 调用内置的 Google Harness² 固定版本，通过当前模型递归改进文本成果，保存答案、评估轨迹和经验。两者直接进入现有 LLM function calling。
- **交付**：会话附件上传、沙箱文件预览 / 下载；停止保留部分正文和已完成工具结果；会话草稿在当前窗口恢复。
- **桌面**：Electron 随包携带 Phoenix release、ERTS 和 Python，独立管理本机数据库、配置与工作目录。Linux 安装包可在本机构建；macOS / Windows 通过原生构建工作流提供构建入口。
- **插件**：兼容 DeepSeek Harness（Cordis）工具插件，支持官方 npm 插件与本地 `.mjs` 插件（见 [docs/plugins.md](docs/plugins.md)）。
- **数据**：SQLite + Ecto — `projects`、`agent_sessions`（含 `project_id`）、`skills`（含 `project_id`、`source`）等。
- **CI**：`.github/workflows/ci.yml`（参考 `idea/` 中「会话 + 流式」产品方向，落地为 compile / format / test）。

## 依赖环境

- **Elixir** 1.15+、**Erlang/OTP**（与发行版匹配）。
- **SQLite**（开发库见 `config/dev.exs`）。

## 快速开始

```bash
cd /path/to/FluxClaw
make setup
# 或: mix deps.get && mix setup
```

创建 **`.fluxclaw/config.json`**（可从 **[.fluxclaw/config.example.json](.fluxclaw/config.example.json)** 复制）：

```json
{
  "openai": {
    "api_key": "sk-你的密钥",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o-mini"
  },
  "sandbox_root": "./flux_claw_sandbox",
  "cache_paths": {
    "external_skills": "",
    "internal_skills": "",
    "history_root": ""
  }
}
```

环境变量可覆盖文件配置：`OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_MODEL`、`FLUX_CLAW_SANDBOX`、`FLUXCLAW_MAX_STEPS`（或 JSON 中 `agents.max_steps`，**`-1` 表示不限制轮次**）、`FLUXCLAW_CACHE_EXTERNAL_SKILLS`、`FLUXCLAW_CACHE_INTERNAL_SKILLS`、`FLUXCLAW_CACHE_HISTORY`、`FLUX_CLAW_CONFIG_PATH`。

启用 **DeepSeek Harness 插件** 时，把 **[.fluxclaw/cordis.example.yml](.fluxclaw/cordis.example.yml)** 复制为 **`.fluxclaw/cordis.yml`**，或在 `FLUXCLAW_CORDIS_CONFIG` 中指定配置路径。

```bash
make serve
# 或: mix phx.server
```

浏览器打开：**http://localhost:4000/**

## Makefile 常用命令

| 目标 | 说明 |
|------|------|
| `make setup` | `mix setup`（依赖、数据库、前端资源） |
| `make test` | `mix test` |
| `make serve` | `mix phx.server` |
| `make precommit` | `mix precommit`（与 AGENTS.md 一致） |
| `make clean-sandbox` | 删除本地沙箱目录（`flux_claw_sandbox`、`tmp/...`） |
| `make clean-assets` | 删除 `priv/static/assets` 构建产物 |
| `make clean-artifacts` | 删除 `_build`、`deps`、沙箱与 assets（**慎用**） |

数据库重置（会清空数据）：

```bash
mix ecto.reset
```

## 测试

```bash
make test
```

## 设计备忘

`idea/idea1.md`、`idea/idea2.md` 记录 Erlang 会话与 LiveView 流式相关思路；实现细节以 `docs/` 与代码为准。

## 许可

见仓库根目录 `LICENSE`。
