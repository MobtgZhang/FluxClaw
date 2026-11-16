# 本轮交付验收

验证日期：2026-11-16；环境：Linux x64。界面改造依据 `/home/mobtgzhang/FluxClaw_suggestion.md`，使用说明见 [工作台](../docs/workbench.md)，构建说明见 [桌面版](../docs/desktop.md)。

## 已通过

- `FLUXCLAW_PYTHON=/tmp/fluxclaw-harness2-venv/bin/python mix precommit`：编译、格式与测试检查通过，55 项测试通过；覆盖原生工具契约、工具调用配对、停止保留内容、文件边界和 Markdown 安全渲染。包含真实 Harness² demo 流程。
- `FLUXCLAW_PYTHON=/tmp/fluxclaw-harness2-venv/bin/python python3 test/integrations/harness2_bridge_smoke.py`：文本适配器通过，8 次确定性模型调用，完成候选执行、改进、选择与经验写入。
- `npm test --prefix desktop`：4 项桌面后端和导航策略测试通过。
- `npm audit --prefix desktop --audit-level=high`：报告 0 个已知漏洞。
- `git diff --check`：通过。

完整桌面 smoke 分别针对开发 Electron 壳、实际 `linux-unpacked/fluxclaw-desktop` 和 AppImage 通过。AppImage 使用 `APPIMAGE_EXTRACT_AND_RUN=1` 解包运行；未验证 FUSE 挂载方式。

```bash
SMOKE_NO_SANDBOX=1 \
SMOKE_EXECUTABLE=/absolute/path/desktop/dist/linux-unpacked/fluxclaw-desktop \
xvfb-run -a npm run test:smoke --prefix desktop

APPIMAGE_EXTRACT_AND_RUN=1 SMOKE_NO_SANDBOX=1 \
SMOKE_EXECUTABLE=/absolute/path/desktop/dist/FluxClaw-0.1.0.AppImage \
xvfb-run -a npm run test:smoke --prefix desktop
```

测试使用独立临时数据目录、本地模型夹具与真实 Phoenix release / SQLite，每次共 6 次模型请求，覆盖：

- 独立启动、随机端口、无凭证请求被拒绝（403）与退出清理。
- 新建任务、刷新恢复草稿、中文输入法 Enter、Shift+Enter。
- SSE 流式正文、向上阅读保持位置、回到最新、最终 Markdown。
- 文件写入、同名工具配对、失败状态、刷新后的历史与实际剪贴板复制。
- 文件浏览、上传、带凭证的独立预览窗口和实际下载。
- `ask_user` 回答后续跑，普通聊天草稿保留。
- 停止后保留部分内容、刷新保持停止状态。
- 390px 深色布局、菜单 / 抽屉键盘焦点、Escape 返回触发按钮。

这里的 `SMOKE_NO_SANDBOX=1` 仅用于当前容器中的 Chromium 启动限制；正常桌面启动不应设置。移动端测试使用桌面 Chromium 视口，未替代真机软键盘验证。

## 安装包

已生成 `desktop/dist/FluxClaw-0.1.0.AppImage` 与 `desktop/dist/fluxclaw-desktop_0.1.0_amd64.deb`，随包包含 Phoenix release、ERTS、Python 和固定版本 Harness² 核心。校验值保存在同目录 `SHA256SUMS`。deb 已成功构建，未执行系统安装。

## 外部依赖与验证范围

AgentSearch 已作为 `agent_search` 原生 LLM 工具接入，并通过 local / sciphi HTTP 契约测试。实际检索需要配置有数据的外部服务；本轮没有部署或填充 Qdrant / PostgreSQL 索引，也未验证历史托管 API 的在线可用性。

Harness² 已内置真实上游核心和文本任务适配器；上述验证使用确定性模型回复，没有调用付费模型，不能视作模型质量评测。未集成上游全部 benchmark 环境或任意代码优化执行器。

macOS / Windows 原生构建工作流已提供，但未在这两个系统运行；签名、公证、自动更新与商店发布尚未配置。当前 Linux 包的系统兼容范围也需在目标发行版上继续验证。
