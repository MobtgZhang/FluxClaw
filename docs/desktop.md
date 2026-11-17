# Electron 桌面版

## 安装与启动

Linux 构建产物位于 `desktop/dist/`：AppImage 可赋予执行权限后启动；deb 使用系统软件安装器安装。随包携带 ERTS、Phoenix release 和 Python 3.12，最终用户无需安装 Elixir 或 Python。首次启动自动迁移数据库，之后在设置中配置 OpenAI 兼容模型，在详情中配置 AgentSearch。

桌面后端仅绑定随机的 `127.0.0.1` 端口，每次启动生成会话凭证。Electron 为页面、资源与 WebSocket 请求添加凭证，普通本地客户端请求返回 403。renderer 启用 contextIsolation、sandbox，关闭 Node 集成和 webview；仅允许应用来源写入普通剪贴板，拒绝其他权限。外链仅允许 HTTP(S) 并交给系统浏览器，文件预览留在带凭证的应用窗口。

应用数据使用 Electron `userData` 目录：Linux 通常 `~/.config/FluxClaw`，macOS 通常 `~/Library/Application Support/FluxClaw`，Windows 通常 `%APPDATA%/FluxClaw`。开发版名称可能为 `fluxclaw-desktop`。可通过 `FLUXCLAW_DESKTOP_DATA` 指定目录。数据库 `fluxclaw.db`、模型配置 `config.json`、`workspaces/`、`cache/` 和 `backend.log` 均保存在这里。密钥为本地配置文件存储，不是系统钥匙串。

`FLUXCLAW_DESKTOP_DATA=/absolute/path` 可显式指定独立数据目录。退出应用会停止后端。启动失败时查看 `backend.log`，应用不显示模型密钥。

## 开发

```bash
make desktop
```

首次使用先运行 `make setup`。`make desktop` 自动安装缺失的 Electron 依赖、构建前端，再打开桌面窗口。开发窗口会启动并管理自己的 Phoenix 后端，使用随机的本机端口和会话凭证；无需提前运行 `mix phx.server`。关闭主窗口、选择退出或在终端按 Ctrl+C，都会停止该后端。其他独立启动的网页服务不受影响。

网页版运行 `make serve`，两端共用前端、后端启动入口、数据库迁移以及开发数据库和模型配置。网页版默认使用 4000 端口；占用时自动从 4001–4019 中寻找可用端口，按终端打印的地址访问。也可用 `make serve PORT=4100` 严格指定端口，按 Ctrl+C 停止服务。桌面版始终使用独立随机端口，可与网页版同时运行。

Linux 未安装 `inotify-tools` 时，两端自动改用轮询监听页面和资源变更，仍支持自动刷新，无需安装额外系统依赖。

依赖和前端已就绪时，也可以直接运行 `npm run dev --prefix desktop`。生产模式始终启动随包 release，不依赖系统 mix。

## 原生构建

在目标操作系统安装 Node 22+、Elixir / OTP、构建工具，先完成 `mix setup`。下载适合当前 OS / 架构的可独立运行 Python 3.12/3.13（例如 python-build-standalone），不能传入仅包含符号链接的 venv。

```bash
npm ci --prefix desktop
# Unix 根目录内应有 bin/python3；Windows 应有 python.exe
export FLUXCLAW_PYTHON_BUNDLE=/absolute/path/to/standalone-python-root
npm run dist --prefix desktop
```

`prepare:backend` 安装插件 bridge 依赖、构建前端、创建含 ERTS 的 release，再复制 release 和 Python；`dist` 用 electron-builder 生成 Linux AppImage/deb、macOS dmg 或 Windows NSIS。不能把 Linux ERTS / Python 拿去打包 Windows 或 macOS。`.github/workflows/desktop.yml` 提供三个系统的手动原生构建入口和产物上传；未配置代码签名或自动更新。

本轮在 Linux x64 实际验证启动和打包。Windows / macOS 构建配置已提供，尚未在对应主机实测；签名、公证和商店发布需要自己的发布身份。Linux ERTS 也依赖构建环境的系统 C 库，发布前应在支持的最旧系统构建并验证。

## 桌面回归

```bash
npm test --prefix desktop
npm run test:smoke --prefix desktop
# Linux 无桌面 CI
xvfb-run -a npm run test:smoke --prefix desktop
# 对真正解包后的程序运行同一回归
SMOKE_EXECUTABLE=/absolute/path/desktop/dist/linux-unpacked/fluxclaw-desktop npm run test:smoke --prefix desktop
```

受限容器可能需要测试专用 `SMOKE_NO_SANDBOX=1` 才能启动 Chromium；正常桌面运行不应设置。测试使用全新临时数据目录和本地 HTTP 模型服务，不会修改个人会话或调用付费模型。

## 分发许可

FluxClaw 和 vendored Harness² 的主体许可证为 Apache-2.0；固定来源和保留声明见 `priv/integrations/harness2_vendor/UPSTREAM.md` 与 `LICENSE`。仅分发 Harness² 核心包，不分发上游 WorkBuddy benchmark 的第三方数据与受限资源。Electron 带有自身 LICENSE / LICENSES.chromium.html，Python 发行目录保留其 LICENSE 文件，ERTS / npm 依赖的许可文件随 release 复制。分发者仍需核对所选 Python 发行版、原生库及额外插件许可。
