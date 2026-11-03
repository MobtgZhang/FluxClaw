# DeepSeek Harness plugin compatibility

FluxClaw can run DeepSeek Harness tool plugins through a Cordis-compatible Node bridge. This keeps the plugin's `apply(ctx, config)` contract intact while exposing registered tools to the existing Elixir agent loop.

## Setup

```bash
make setup
```

`make setup` installs the bridge dependencies in `priv/plugins/bridge`. The bridge uses `@deepseek-ai/cordis`, so official plugin packages receive a real Cordis context rather than a partial shim.

## Loading plugins

Copy the DeepSeek-style configuration to `.fluxclaw/cordis.yml`:

```yaml
- id: tool-todo
  name: '@deepseek-ai/dsh-tool-todo'
  config:
    allowParallelInProgress: false
```

Local plugins use absolute paths:

```yaml
- id: local-greet
  name: '/absolute/path/to/greet-plugin.mjs'
```

The loader supports the common Cordis patch form as well:

```yaml
- insert:
    - id: local-greet
      name: '/absolute/path/to/greet-plugin.mjs'
```

Set `FLUXCLAW_CORDIS_CONFIG` to point at another file. Entries with `disabled: true` (including `!!js` expressions) are skipped.

The runtime only starts the Node sidecar when its Cordis config file exists. Missing tool names continue to fall back to FluxClaw's built-in tools.

## Host seams

The bridge provides the following Cordis services:

- `ctx.tools.register/1` for DeepSeek `defineTool` definitions.
- `ctx.tools.get/1`, `definitions/0`, `schemas/0`, and `execute/3`.
- `ctx.systemPrompt.register/1` for model-visible prompt sections.
- `ctx.sessionProjections.register/1` for reversible session projections.
- Minimal `ctx.shell` and `ctx.workingDirectory` adapters.

Tools are injected into the same OpenAI-compatible tool list used by built-in tools. Their `execute()` function runs in the plugin's Node process, `output.render()` produces the model-facing text, and `exec.agent.session.append()` events are returned to Elixir for logging.

## Plugin manager UI

The right-hand sidebar of the chat UI has a 插件管理 tab backed by `FluxClaw.Plugins.summary/0`:

- Runtime badge (running / not running) plus the resolved config path (`FLUXCLAW_CORDIS_CONFIG` / `DSH_CORDIS_CONFIG` / `.fluxclaw/cordis.yml`).
- Each configured plugin with its source kind (`npm` vs `local`), load state, and contributed tool count.
- The full list of plugin-registered OpenAI tool schemas and system-prompt sections.
- 刷新状态 re-queries the runtime; the LiveView also subscribes to the `flux_claw:plugins` topic and refreshes on `{:plugin_loaded, ...}` / `{:plugin_tool_registered, ...}` / `{:plugin_tool_unregistered, ...}` broadcasts.

## Safety

Plugin code runs outside the BEAM sandbox and has Node.js capabilities. Only install plugins from trusted sources. DeepSeek plugins that depend on host seams FluxClaw does not provide will remain pending or fail at load, rather than being silently stubbed.
