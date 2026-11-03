# 原子工具与安全说明

## 已注册工具（`FluxClaw.Tool.modules/0`）

| 工具名 | 作用 |
|--------|------|
| `file_read` / `file_write` / `file_patch` | 在会话沙箱内读写/补丁文件。默认经 Diff 审查（见下），保留后才写盘。 |
| `apply_patch` | 对沙箱内文件应用统一 diff（纯新增视为新建文件），同样走 Diff 审查。 |
| `promote_checkpoint` | 将指定检查点（L1/L2）结晶为 L3 技能（自进化路径，见 `agent-and-memory.md`）。 |
| `shell_execute` | 在沙箱子目录下执行 shell（Unix: `/bin/sh -c`，Windows: `cmd /c`），带超时与输出截断。 |
| `web_fetch` | 对公开 `http(s)` URL 做 GET，剥离部分 HTML 标签后返回文本；禁止常见内网/本地主机名。 |
| `task_plan` | 生成结构化步骤并写入 L1 scratch。 |
| `ask_user` | 暂停并向用户提问。 |
| `update_working_checkpoint` | 写入检查点。 |
| `start_long_term_update` | 长期事实/L2 更新。 |

## Diff 审查（Codex / Claude Code 式代码修改确认）

- `file_write` / `file_patch` / `apply_patch` 默认不直接写盘，而是生成统一 diff（`FluxClaw.Tools.Diff`）并返回 `{:suspend_review, ref, payload}`；Worker 暂停循环，向会话 topic 广播 `{:diff_proposed, ref, payload}`。
- UI（聊天底部的 diff 审查块）提供「保留修改 / 拒绝」；决定经 `Orchestrator.reply_diff_review/3` 回传 `{:diff_review_reply, ref, decision}`。
- 保留时 Worker 调 `FluxClaw.Tools.Review.apply_kept/1` 才真正写盘；拒绝则不产生任何变更，Agent 继续运行。
- 可用 `config :flux_claw, :agents, review_edits: false` 关闭审查（直接写盘）。

## 沙箱

- 所有相对路径经 `FluxClaw.Tools.Sandbox.resolve!/2` 解析，必须落在 `ctx.sandbox_root` 内，防止 `../` 逃逸。

## Shell 风险

- `shell_execute` 能力极强，默认仍限制在沙箱工作目录内，并使用 `Task.yield/2` 超时杀掉子任务。
- 生产环境建议：网络隔离、更低 `max_steps`、或在上层网关禁用该工具。

## Web 抓取

- 仅允许 `http`/`https`；对 `localhost`、`127.0.0.1`、`10.*`、`192.168.*` 等做了基础 SSRF 防护，**非完整**内网防护，部署时勿暴露于不可信网络。

## 配置示例

见仓库根目录 `.fluxclaw/config.example.json` 与 `README.md` 环境变量说明。
