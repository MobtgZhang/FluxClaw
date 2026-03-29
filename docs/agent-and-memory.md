# 智能体循环与记忆分层

## GenericAgent 式主循环

`FluxClaw.Agents.AgentWorker` 实现「LLM → 工具 → 再 LLM」循环：

1. 用户消息写入 `agent_messages` 并进入内存中的 `conversation`（OpenAI Chat 格式列表）。
2. 调用 `LLM.stream/4`（或底层 OpenAI SSE）得到助手内容、可选 **reasoning** 流、以及 `tool_calls`。
3. 若有工具调用：向 UI 广播 `tool_start` / `tool_done`，将 `role: tool` 消息追加到 `conversation`，`continue` 下一轮。
4. 若无工具调用：持久化助手消息，可选触发技能结晶（见下）。

## 流式与 UI 分区

- **reasoning_delta / reasoning_done**：模型若返回 `reasoning_content`（或兼容字段），通过独立 PubSub 事件输出，LiveView 中与正文流式区分开展示（Markdown）。
- **assistant_delta / assistant_done**：主回答流式与落盘。
- **tool_***：作为「流程/工具时间线」穿插在对话流中，贴近 Cursor Agent 式体验。

## L0–L3 记忆（概念映射）

| 层级 | 实现要点 |
|------|-----------|
| **L0** | `config :flux_claw, :memory_l0, rules: [...]` 注入系统提示；可扩展为固定规则文件。 |
| **L1** | Worker 进程内 `l1` map；`task_plan` 工具通过 `opts` 写入本轮「计划草稿」，供后续轮次系统消息引用。 |
| **L2** | `FluxClaw.Memory.Layered` 中 `l2` 事实表；`update_working_checkpoint` / `start_long_term_update` 等工具可写回。 |
| **L3** | SQLite `skills` 表 + 可选 **外部目录**（`Application.get_env(:flux_claw, :cache_paths)[:external_skills]`）下的 `*.md` 等文件，经 `Memory.list_skills_for_prompt/2` 合并检索后写入系统提示。 |

## 自进化与 OpenClaw 思路对齐

公开资料中 OpenClaw 系实践强调：**失败反馈、分层记忆、人在回路（批准后再写入）**。FluxClaw 中对应钩子包括：

- `ask_user` 工具：高风险操作前暂停等待用户输入。
- `crystallize_skills` + `crystallize_mode: :confirm`：在确认模式下不直接写入技能，而是向 UI 发送 `skill_proposal`，由用户显式「接受并保存」后再 `Memory.create_skill/1`。
- 外部 skills 目录：便于与 Cursor / 仓库内 Markdown 技能库对齐，实现「检索增强」而非仅数据库。

配置见 `config/config.exs` 中 `:agents` 与 `:cache_paths`。`agents.max_steps` 为 **`-1`** 时表示不在 Worker 内限制 LLM↔工具循环轮次（内部用大上限实现）；正整数为硬上限。
