# FluxClaw

基于 **BEAM（Erlang/OTP 虚拟机）** 的多 Agent 对话应用：**Phoenix LiveView** 提供类 **ChatGPT** 的单页界面；每个会话对应独立的 `AgentWorker`（GenServer）+ `DynamicSupervisor`，流式事件经 **PubSub** 推到浏览器（对齐仓库内 [`idea/idea1.md`](idea/idea1.md)、[`idea/idea2.md`](idea/idea2.md) 的设计描述）。

与 [CuteClaw](https://github.com/MobtgZhang/CuteClaw)（Zig 核心、JSON 快照、技能进化门禁）相比：FluxClaw 将 **记忆 / 检查点 / 技能** 落在 **SQLite + Ecto**，在 LiveView 中提供 **侧栏会话、主对话流、检查点条、技能库（可删）** 等更易用的控制台；**不包含** CuteClaw 的 Zig CLI 与 `store.json` 格式兼容层（后续可做导入/导出）。

## 功能概要

- OTP：`Registry` + `DynamicSupervisor` 按会话拉起 Agent；工具调用沙箱目录按会话隔离。
- LLM：OpenAI 兼容 Chat Completions（优先读项目下 `.fluxclaw/config.json`，环境变量可覆盖）；测试环境使用 Mock。
- 工具：`file_read` / `file_write` / `file_patch` / `ask_user` / `update_working_checkpoint` / `start_long_term_update`（见 `lib/flux_claw/tool.ex`）。
- 前端：`/chat` 与 `/chat/:id` 为 ChatGPT 式布局；旧路径 `/agents` 会 **302** 到 `/chat`。
- 观测：Telemetry 指标（如 `flux_claw.agent.steps`）；开发环境可访问 `/dev/dashboard`。

## 依赖环境

- **Elixir** 1.15+、**Erlang/OTP**（与 Elixir 发行版匹配）。
- **SQLite**（开发库为 `priv/repo/flux_claw_dev.db`，见 `config/dev.exs`）。
- 调用真实模型时在 **`.fluxclaw/config.json`** 中填写 API Key（或设置 `OPENAI_API_KEY` 等环境变量覆盖）。

## 运行应用（开发）

在项目根目录执行：

```bash
cd /path/to/FluxClaw
mix deps.get
mix setup
```

若数据库尚未创建或迁移未执行：

```bash
mix ecto.create
mix ecto.migrate
```

在项目根目录创建 **`.fluxclaw/config.json`**（可复制 **`.fluxclaw/config.example.json`** 为 `config.json` 再改密钥；示例可提交仓库，`config.json` 已在 `.gitignore` 中忽略）：

```json
{
  "openai": {
    "api_key": "sk-你的密钥",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o-mini"
  },
  "sandbox_root": "./flux_claw_sandbox"
}
```

也支持顶层平铺键名：`openai_api_key`、`openai_base_url`、`openai_model`、`flux_claw_sandbox`（或 `sandbox_root`）。

**环境变量优先于 JSON**：`OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_MODEL`、`FLUX_CLAW_SANDBOX` 任一设置后会覆盖文件中的对应项。自定义配置文件路径可设置 **`FLUX_CLAW_CONFIG_PATH`**。

然后启动：

```bash
mix phx.server
```

浏览器打开：**http://localhost:4000/chat**（或首页链接进入）。

使用 **IEx**：

```bash
iex -S mix phx.server
```

## 测试

测试环境使用 **SQLite**（见 `config/test.exs`）：

```bash
mix test
```

涉及在测试中启动的 `AgentWorker` 会配合 `Ecto.Adapters.SQL.Sandbox.allow/3` 访问数据库。

## 故障排查

| 现象 | 处理 |
|------|------|
| `missing_api_key` | 在 `.fluxclaw/config.json` 填写 `openai.api_key`，或设置 `OPENAI_API_KEY` 后重启 `mix phx.server`。 |
| 数据库错误 | 执行 `mix ecto.create` 与 `mix ecto.migrate`；开发库路径见 `config/dev.exs`。 |
| 会话页无流式更新 | 确认已打开 `/chat/:id` 且该会话的 Worker 已 `subscribe`（切换会话会自动切换订阅）。 |

## 仓库结构（节选）

| 路径 | 说明 |
|------|------|
| `lib/flux_claw/agents/` | 会话、Orchestrator、`AgentWorker` |
| `lib/flux_claw_web/live/chat_live.ex` | ChatGPT 式主界面 |
| `lib/flux_claw/llm/` | LLM 行为与 OpenAI 适配 |
| `lib/flux_claw/tools/` | 原子工具与沙箱 |
| `lib/flux_claw/memory.ex` | 技能、检查点查询 |
| `idea/` | 架构备忘（Erlang 会话 / LiveView 流式） |

## 许可

见仓库根目录 `LICENSE`。
