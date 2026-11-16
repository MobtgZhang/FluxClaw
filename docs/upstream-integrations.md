# AgentSearch 与 Harness² 上游集成调查

调查日期：2026-11-16。本文保留上游接口调查与最初的工程建议，下面先列出已经落地的集成。

## 本项目实施状态

- `FluxClaw.Tools.AgentSearch` 已注册为原生 `agent_search`，支持下述 local / sciphi 两种契约。Req.Test 验证请求、凭证、空字段、错误和引用输出；未连接已填充的外部检索索引。
- `FluxClaw.Tools.Harness2` 已注册为原生 `harness2_optimize`，固定的上游核心位于 `priv/integrations/harness2_vendor`。`harness2_runner.py` 实现下文建议的文本 BenchmarkAdapter / Proposer，通过 stdio 请求 FluxClaw 当前模型，由 Elixir/Req 发起模型请求。具备调用预算、总时限、文本上下文限制、独立运行目录和跨次经验库。
- 已执行上游 demo 的 parallel / sequential 流程，也用确定性模型回复完整运行文本 adapter 的优化、选择和经验流程。后者验证接口和执行路径，不代表在线付费模型质量评测。
- Electron 包含 Phoenix release / ERTS / Python。工具集成设置和产物预览下载已经接入工作台。

当前使用方式见 [工作台说明](workbench.md) 和 [桌面说明](desktop.md)。下文“建议 / 下一步接口”属于调查时的原始分析，对应适配器现已实现，完整 benchmark 执行器仍不在本项目接入范围内。

## 核实版本与结论

- [SciPhi-AI/agent-search](https://github.com/SciPhi-AI/agent-search) 的 GitHub API 返回同名仓库，未重定向、未归档、未禁用。调查时 `main` 为 `b47b9327f9a47d09995a09a3079b718d5ddb73c5`，最后推送时间为 2024-04-22。它是 Python 搜索/RAG 框架，具有可直接用 Elixir `Req` 调用的 HTTP 搜索接口。[仓库元数据](https://api.github.com/repos/SciPhi-AI/agent-search)、[固定版本 README](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/README.md)
- [google-research/harness2](https://github.com/google-research/harness2) 同样未重定向、未归档、未禁用。调查时 `main` 为 `6868817518876de8fd170c6a8354daca273b6191`，最后推送时间为 2026-11-02。它实现递归优化 agent 周边提示词、工具、记忆、技能等组件的 Propose–Probe–Compose 流程，支持 OpenCode/Codex 执行器和三个工作任务 benchmark。[仓库元数据](https://api.github.com/repos/google-research/harness2)、[固定版本 README](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/README.md)
- 集成落点：AgentSearch 用内置原子工具发起真正的检索请求；Harness² 用内置工具启动固定版本 Python 包并返回结构化产物。两者进入 `FluxClaw.Tool`，让现有 `AgentWorker` 直接获得 OpenAI function schema 和执行结果。Electron 只承载 Phoenix 工作台，不应承担 Python 包或模型密钥的调用逻辑。这是基于本仓库 `FluxClaw.Tool` / `FluxClaw.Tools.WebFetch` 的工程建议。

## AgentSearch：两个不相同的 `/search` 契约

自托管服务的契约位于 [app/server.py](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/app/server.py)，由旧版 [AgentSearchClient](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/core/client.py) 调用：

```http
POST /search
Content-Type: application/json

{
  "query": "Phoenix LiveView streams",
  "limit_broad_results": 1000,
  "limit_deduped_url_results": 100,
  "limit_hierarchical_url_results": 25,
  "limit_final_pagerank_results": 10
}
```

响应为 `{"results": [...]}`。`GET /health` 返回 `{"status":"ok"}`；服务在导入时就初始化搜索引擎，缺失索引、模型或 PageRank 数据时，健康检查所在进程也无法启动。服务只检查数量的上限，依次为 `3000/300/75/30`，没有完整的正数验证，也没有实现认证。客户端附带 Bearer token 不代表本地服务会验证它。[服务实现](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/app/server.py)

README 推荐的 `SciPhi` 则调用托管接口：`POST /search` 请求为 `{"provider":"agent-search","query":"..."}`，期望顶层数组。它还调用 `POST /search_rag`，将 `other_queries` 改名为 `related_queries` 后返回 `response/related_queries/search_results`。这个 RAG 路由没有出现在仓库的自托管 FastAPI 服务中，不能当作本地现成功能。[SciPhi provider 实现](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/providers/sciphi.py)

两种客户端都默认 `https://api.sciphi.ai`，使用 `SCIPHI_API_BASE`、`SCIPHI_API_KEY`。这里只核实了源码中的历史托管契约，没有凭据，也没有验证该托管服务目前可用。FluxClaw 应显式配置 `local` / `sciphi` 模式，或明确记录自己支持的请求/响应兼容范围；不要向一个地址盲目混发两种请求。结果字段包括 `score/url/title/dataset/metadata/text`，其中部分字段可空。[结果模型](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/core/search_types.py)

### 本地运行成本与约束

包声明 Python `>=3.9,<3.12`，依赖 Qdrant、Transformers、NumPy、Pydantic 1、旧版 OpenAI `0.27.8` 等；FastAPI、Uvicorn、Torch、PostgreSQL 驱动不在完整安装依赖中。仅 `pip install agent-search` 不能获得已填充的本地搜索服务。[pyproject.toml](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/pyproject.toml)

本地引擎要求 Qdrant collection、具有 URL/文本块/768 维 embedding 的 PostgreSQL 表、embedding 模型和域名 PageRank CSV。默认模型是 `jinaai/jina-embeddings-v2-base-en`，加载时启用了 `trust_remote_code=True`；应固定审核过的模型版本并隔离运行。配置示例将服务绑定 `0.0.0.0:8000`，且含示例数据库口令；实际服务应放在受控内网或回环地址并另设认证。[search/base.py](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/agent_search/search/base.py)、[data/config.ini](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/data/config.ini)

推荐 Phoenix 适配器只接收 `query` 和受限结果数；由服务器配置 base URL 和 token，通过 `Req.post` 发 JSON，设置超时、限制响应大小、保留来源 URL。LLM 不应传入任意服务地址或 token。结果文本作为外部材料，不应提升为系统指令。未配置服务时返回清晰的配置错误，而不是伪造搜索结果。无需把 Python 搜索栈放进 Phoenix 或 Electron。

## Harness²：真正可执行的最小集成

上游没有 `HarnessConfig`，也没有接收任意 Python 文件的通用 `runner` 命令。公开 CLI `harness2` 的 benchmark 参数仅接受 `jb/wb/lab`。`harness2-bridge` 是给 Codex 使用的 Responses API 模型代理，不是工作台任务 RPC 服务。[CLI 参数](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/cli/_common.py)、[bridge](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/cli/bridge.py)

不需要模型凭据的实际入口是：

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python --no-deps -e /path/to/pinned/harness2
.venv/bin/python -m harness2.cli.demo --output /absolute/session/sandbox/harness2/run-id --k 1 --mode parallel
```

核心包没有运行依赖，Python 范围为 `>=3.12,<3.14`。演示不需要 `render` 或 `bridge` extras，不需要安装 OpenCode、Codex 或 benchmark 数据；它使用 `OpencodeSubstrate` 的组件定义，但执行器实际是 Python `subprocess.run`。[pyproject](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/pyproject.toml)、[demo 实现](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/demo.py)

`--mode` 为 `parallel/sequential/both`，`--k` 是正整数。demo 使用两个固定的带正负金额账本任务，真实执行候选 Python 脚本，使用确定性的 `DemoProposer` 修改“忽略负数”错误，再执行真正的递归、选择和经验持久化流程。它能验证 Harness² 的完整本地机制，但不代表对任意任务进行模型驱动优化。[demo CLI](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/cli/demo.py)、[DemoProposer](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/demo.py)

### 已执行验证

在 Python 3.12.14 的隔离 venv 中，安装上述精确版本并运行 `--k 1 --mode parallel`：退出码 `0`，完成 `2` 个任务，失败 `0`，实际执行 `8` 次 Python，编辑器调用 `8` 次；选中产物分别为 `Total: 85.15` 与 `Total: 20.25`。这次验证没有配置任何模型凭据或访问付费模型。

复现文件（调查环境临时目录，不属于项目发布资源）：

- 上游完整固定版本源：`/tmp/fluxclaw-upstream-harness2-archive`。Git clone 遇到 TLS 中断，改用 GitHub API 的该 commit tarball 成功下载。
- venv：`/tmp/fluxclaw-harness2-venv`。
- 本次原始产物：`/tmp/fluxclaw-harness2-smoke`。

工作台工具应接受受限的 `mode/k`，由 FluxClaw 生成沙箱内唯一运行目录，再以参数数组调用解释器和固定模块；不要把用户输入拼进 shell。建议产品层先限制 `1 <= k <= 3` 并设置整个进程组的执行时限。上游 demo 的每次子进程执行限时默认 `10` 秒，但 CLI 没有总时限。超时应同时终止子进程，避免仅停止 BEAM Task 而留下 Python 工作进程。[本地 execute](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/demo.py)

### 产物路径与返回契约

以输出根目录 `OUTPUT`、`k=1`、`parallel` 为例：

- `OUTPUT/demo.json`：`domain/n_tasks/seed/done/failed/tasks/execution_count/editor_calls`，适合作为工具返回摘要。
- `OUTPUT/runs/demo-oc-agg1/ledger-1/summary.json` 和 `ledger-2/summary.json`：任务状态、候选阶段、账本、选择、经验。`modes.agg.ledger` 有 `R=4/P=3`；`selections.agg.chosen_run_dir` 指向最终产物目录。
- `OUTPUT/executions/demo-oc-agg1/ledger-1/{base1,inv1,dom1,agg1}/{answer.txt,trajectory.md}`：各次实际执行的答案与轨迹。
- `OUTPUT/library/k1/agg/accounting/INDEX.md` 与 `harnesses/<task>/{harness/*,EXPERIENCE.md}`：持久化采用的组件和经验。
- `OUTPUT/sources/<task>/ledger.csv` 与 `OUTPUT/base/*`：输入和初始组件树。

`sequential` 的模式键为 `seq`，final 标签为 `c1`；两种模式共享的任务 summary 仍位于 `runs/demo-oc-agg1/<task>/summary.json`。目录命名由 `Namespace/ns()` 统一定义。[schedule.py](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/core/schedule.py)、[demo.py](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/demo.py)

读取产物时应校验路径位于会话沙箱，返回摘要和文件引用，限制递归文件数和读取大小。UI 可以展示状态、采用候选、最终答案、执行次数和经验。不能把整个候选目录无界塞回模型上下文。

### 任意 FluxClaw 任务的下一步接口

真实扩展接口为 Python `BenchmarkAdapter`：提供 `spec/substrate/tasks/domain_of/task_prompt/task_files/execute/delivered/trajectory/deliverable_files/deliverable_text/base_harness/validate_tree/score`。静态配置使用 `BenchSpec`、`BenchPrompts`、`ChannelSpec`；执行器接口是 `Substrate.surface/materialise/execute/read_trajectory/preflight`。[core/spec.py](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/core/spec.py)、[substrate/base.py](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/substrate/base.py)

核心入口为 `core.schedule.run_task(task_id, k, *, adapter, prop, runs_root, modes=("agg",), ...)`；跨任务持续经验使用 `run_domain(domain, task_ids, k, *, adapter, prop, runs_root, library_root, modes=...)`。`prop` 通常是 `Proposer`，也可像 `DemoProposer` 一样覆盖 `call()`，返回真正的 `Reply` 与编辑过的组件树。因此后续可以实现 FluxClaw adapter 和调用本仓库模型配置的 proposer，让上游负责递归算法、本仓库负责实际 agent 执行；这需要新的适配代码，不能仅通过环境变量就变成现成功能。[schedule](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/core/schedule.py)、[proposer](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/core/proposer.py)

## 模型运行、安全与许可证

完整 benchmark 建议 Linux、Python 3.12、Node 20+、uv 和 Google Cloud CLI；LAB 另需 Pandoc/Poppler，WorkBuddy 另需 Docker。默认模型路径依赖 Vertex 凭据；Codex 可接另外配置的 Responses API 地址，并非只能使用 Codex 官方账号。准备环境和检查命令分别为 `harness2-setup <bench>`、`harness2-check --bench <bench>`；`--dry-run` 能预览部分操作。[SETUP](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/docs/SETUP.md)

上游 Codex 执行明确带 `--dangerously-bypass-approvals-and-sandbox` 和 `--dangerously-bypass-hook-trust`，默认网络访问不受限。不要把该执行器直接用于桌面宿主上的不可信任务。benchmark 执行应放在容器或独立作业环境中；默认环境过滤只移除特定列表中的密钥，其他变量仍可能传递给子进程。[Codex argv](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/substrate/codex.py)、[环境/网络说明](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/docs/SETUP.md)、[实验说明](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/docs/EXPERIMENTS.md)

单模式每个任务的核心预算是 `4k` 次 rollout 和 `3k` 次改进阶段，选择与经验反思在这个账本之外；模型运行成本不能理解为只调用模型 `k` 次。[ledger.py](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/harness2/core/ledger.py)

两个主体项目都是 Apache-2.0。分发源码或衍生代码需保留许可证与适用声明，修改文件需注明修改；数据与依赖的许可另行适用。Harness² 的第三方代码包括 Apache-2.0、MIT 与 Tencent 自定义许可证；WorkBuddy 许可证有涉及欧盟使用的地域限制，不能用主体的 Apache-2.0 覆盖该限制。AgentSearch 数据集、模型、托管 API 的授权和服务条款也不能从仓库代码许可证推定。本次未下载或分发这些数据。[AgentSearch LICENSE](https://github.com/SciPhi-AI/agent-search/blob/b47b9327f9a47d09995a09a3079b718d5ddb73c5/LICENSE)、[Harness² LICENSE](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/LICENSE)、[第三方许可说明](https://github.com/google-research/harness2/blob/6868817518876de8fd170c6a8354daca273b6191/dependencies/README.md)
