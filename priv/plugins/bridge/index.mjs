#!/usr/bin/env node
import { createRequire } from 'node:module'
import { AsyncLocalStorage } from 'node:async_hooks'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { Context, Service } from '@deepseek-ai/cordis'
import { parse } from 'yaml'

const pluginContext = new AsyncLocalStorage()
const loadedPlugins = new Map()
const sessionEventBuffer = []

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function sendError(error, context = {}) {
  send({
    type: 'error',
    message: error instanceof Error ? error.message : String(error),
    ...context,
  })
}

function jsTag() {
  return {
    tag: 'tag:yaml.org,2002:js',
    resolve: input => ({ __js: String(input) }),
  }
}

function evaluateJs(value, scope) {
  if (Array.isArray(value)) return value.map(item => evaluateJs(item, scope))
  if (value && typeof value === 'object' && Object.hasOwn(value, '__js')) {
    const source = String(value.__js)
    const evaluator = new Function('ctx', 'dshHomePath', 'process', `return (${source})`)
    return evaluator(scope.ctx, scope.dshHomePath, { env: process.env })
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, evaluateJs(item, scope)]))
  }
  return value
}

function parseCordisConfig(configPath) {
  const body = fs.readFileSync(configPath, 'utf8')
  const rows = parse(body, { customTags: [jsTag()] })
  const scope = {
    ctx: null,
    dshHomePath: segment => path.resolve(
      process.env.FLUXCLAW_DSH_HOME || process.env.DSH_HOME || path.dirname(configPath),
      String(segment || ''),
    ),
  }

  const entries = Array.isArray(rows)
    ? rows.flatMap(row => (row && Array.isArray(row.insert) ? row.insert : [row]))
    : []

  return entries
    .filter(entry => entry && typeof entry === 'object')
    .map(raw => {
      const entry = { ...raw }
      entry.id = String(entry.id || entry.name || `plugin-${entries.indexOf(raw) + 1}`)
      entry.config = entry.config == null ? {} : evaluateJs(entry.config, scope)
      if (entry.disabled && typeof entry.disabled === 'object' && Object.hasOwn(entry.disabled, '__js')) {
        entry.disabled = evaluateJs(entry.disabled, scope)
      }
      return entry
    })
    .filter(entry => entry.disabled !== true)
}

function resolveSpecifier(name, configPath) {
  const configBase = path.dirname(configPath)
  const bridgeBase = path.dirname(import.meta.url.replace(/^file:\/\//, ''))
  const require = createRequire(path.join(bridgeBase, 'package.json'))
  const resolved = require.resolve(name, { paths: [bridgeBase, configBase] })
  return pathToFileURL(resolved).href
}

async function importPlugin(name, configPath) {
  if (path.isAbsolute(name) || name.startsWith('./') || name.startsWith('../')) {
    const target = path.resolve(path.dirname(configPath), name)
    return import(pathToFileURL(target).href)
  }
  return import(resolveSpecifier(name, configPath))
}

function pluginModule(module) {
  const candidate = module.default ?? module
  if (typeof candidate === 'function') return candidate
  if (candidate && (typeof candidate.apply === 'function' || candidate.prototype?.apply === 'function')) {
    return candidate
  }
  if (module && typeof module.apply === 'function') return module
  throw new Error('plugin does not export apply(), an apply object, or a function')
}

function wrapFunctionPlugin(plugin) {
  if (typeof plugin === 'function' && plugin.prototype instanceof Service) return plugin
  if (typeof plugin !== 'function') return plugin
  return {
    name: plugin.name,
    inject: plugin.inject,
    Config: plugin.Config,
    apply(ctx, config) {
      return pluginContext.run({ ctx, pluginId: plugin.name }, () => plugin(ctx, config))
    },
  }
}

function wrapObjectPlugin(plugin) {
  if (typeof plugin === 'function') return wrapFunctionPlugin(plugin)
  return {
    name: plugin.name,
    inject: plugin.inject,
    Config: plugin.Config,
    apply(ctx, config) {
      const pluginId = plugin.name || 'unknown'
      return pluginContext.run({ ctx, pluginId }, () => plugin.apply(ctx, config))
    },
  }
}

function toolSchema(tool) {
  return {
    name: tool.name,
    description: tool.description ?? '',
    parameters: tool.parameters ?? { type: 'object', properties: {} },
  }
}

function contentToText(content) {
  if (typeof content === 'string') return content
  if (content == null) return ''
  if (Array.isArray(content)) {
    return content
      .map(block => {
        if (block?.type === 'text') return block.text ?? ''
        if (typeof block === 'string') return block
        return JSON.stringify(block)
      })
      .filter(Boolean)
      .join('\n')
  }
  return JSON.stringify(content)
}

function drainSessionEvents() {
  const events = [...sessionEventBuffer]
  sessionEventBuffer.length = 0
  return events
}

function registerPluginEffect(pluginId, disposer) {
  const ctx = pluginContext.getStore()
  const activeContext = ctx?.ctx
  if (activeContext?.effect) {
    return activeContext.effect(() => disposer)
  }

  throw new Error(`plugin ${pluginId} has no active Cordis context for effect registration`)
}

class ToolsService extends Service {
  tools = new Map()

  register(definition, _options = {}) {
    if (!definition || typeof definition.name !== 'string' || definition.name === '') {
      throw new Error('tool definition must have a non-empty name')
    }
    if (typeof definition.execute !== 'function') {
      throw new Error(`tool ${definition.name} must have an execute() function`)
    }

    const pluginId = pluginContext.getStore()?.pluginId ?? 'unknown'
    const previous = this.tools.get(definition.name)
    this.tools.set(definition.name, definition)
    send({
      type: 'tool_registered',
      pluginId,
      tool: toolSchema(definition),
      replacing: previous != null,
    })

    return registerPluginEffect(pluginId, () => {
      if (this.tools.get(definition.name) === definition) {
        this.tools.delete(definition.name)
        send({ type: 'tool_unregistered', pluginId, name: definition.name })
      }
    })
  }

  get(name) {
    return this.tools.get(name)
  }

  definitions() {
    return [...this.tools.values()]
  }

  schemas() {
    return [...this.tools.values()].map(toolSchema)
  }

  async execute(name, args, exec = {}) {
    const tool = this.tools.get(name)
    if (!tool) throw new Error(`plugin tool not found: ${name}`)
    const value = await tool.execute(args, {
      agent: exec.agent,
      session: exec.agent?.session,
      signal: exec.signal,
      cwd: exec.cwd,
      sandboxRoot: exec.sandboxRoot,
      sessionId: exec.sessionId,
    })
    const rendered = tool.output?.render ? tool.output.render(args, value) : value
    return { value, content: contentToText(rendered) }
  }

}

class SystemPromptService extends Service {
  register(section) {
    if (!section || typeof section.id !== 'string' || typeof section.content !== 'string') {
      throw new Error('system prompt section requires string id and content')
    }
    const pluginId = pluginContext.getStore()?.pluginId ?? 'unknown'
    const payload = {
      id: `${pluginId}:${section.id}`,
      pluginId,
      title: section.title ?? section.id,
      content: section.content,
      priority: section.priority ?? 100,
    }
    send({ type: 'prompt_section_registered', section: payload })
    return registerPluginEffect(pluginId, () => {
      send({ type: 'prompt_section_unregistered', id: payload.id })
    })
  }

}

class SessionProjectionsService extends Service {
  projections = new Map()

  register(definition) {
    if (!definition || typeof definition.key !== 'string') {
      throw new Error('session projection requires a string key')
    }
    const pluginId = pluginContext.getStore()?.pluginId ?? 'unknown'
    const key = `${pluginId}:${definition.key}`
    this.projections.set(key, definition)
    return registerPluginEffect(pluginId, () => {
      this.projections.delete(key)
    })
  }

  apply(key, state, event) {
    const definition = this.projections.get(key)
    if (!definition) return state
    return definition.apply(state, event)
  }
}

class ShellService extends Service {
  async execute(_command, _options = {}) {
    throw new Error('plugin shell execution is disabled in FluxClaw')
  }
}

class WorkingDirectoryService extends Service {
  get root() {
    return process.cwd()
  }

  async resolve(relativePath) {
    return path.resolve(this.root, String(relativePath || '.'))
  }
}

function createExec(request) {
  const sessionId = request.sessionId
  const agent = {
    id: sessionId,
    session: {
      id: sessionId,
      append(eventType, data) {
        sessionEventBuffer.push({ type: eventType, data, pluginId: request.pluginId })
      },
    },
  }
  return {
    agent,
    session: agent.session,
    sessionId,
    cwd: request.cwd,
    sandboxRoot: request.sandboxRoot,
    signal: request.signal,
  }
}

const context = new Context()
const tools = new ToolsService(context, 'tools')
new SystemPromptService(context, 'systemPrompt')
new SessionProjectionsService(context, 'sessionProjections')
new ShellService(context, 'shell')
new WorkingDirectoryService(context, 'workingDirectory')

const requestState = new Map()
let seq = 0

function request(message, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = `req-${++seq}`
    const timer = setTimeout(() => {
      requestState.delete(id)
      reject(new Error(`bridge request timed out: ${message.type}`))
    }, timeoutMs)
    requestState.set(id, { resolve, reject, timer })
    send({ id, ...message })
  })
}

function settleRequest(message) {
  const pending = requestState.get(message.id)
  if (!pending) return
  requestState.delete(message.id)
  clearTimeout(pending.timer)
  if (message.ok) pending.resolve(message)
  else pending.reject(new Error(message.error || 'bridge request failed'))
}

async function loadEntry(entry, configPath) {
  const module = await importPlugin(entry.name, configPath)
  const plugin = wrapObjectPlugin(pluginModule(module))
  const id = entry.id
  loadedPlugins.set(id, { entry, plugin })
  const fiber = await context.plugin(plugin, entry.config)
  loadedPlugins.set(id, { entry, plugin, fiber })
  send({ type: 'plugin_loaded', id, name: plugin.name || entry.name })
}

async function loadAll(configPath) {
  const entries = fs.existsSync(configPath) ? parseCordisConfig(configPath) : []
  send({ type: 'config_loaded', count: entries.length, path: configPath })
  for (const entry of entries) {
    try {
      await loadEntry(entry, configPath)
    } catch (error) {
      loadedPlugins.delete(entry.id)
      sendError(error, { pluginId: entry.id })
    }
  }
  send({ type: 'ready', tools: tools.schemas() })
}

async function callTool(message) {
  const exec = createExec(message)
  const { content } = await tools.execute(message.name, message.args, exec)
  send({
    type: 'tool_result',
    id: message.id,
    ok: true,
    content,
    events: drainSessionEvents(),
  })
}

process.on('uncaughtException', error => sendError(error))
process.on('unhandledRejection', error => sendError(error instanceof Error ? error : new Error(String(error))))

process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  for (const line of chunk.split('\n')) {
    if (line.trim() === '') continue
    let message
    try {
      message = JSON.parse(line)
    } catch (error) {
      sendError(error, { line })
      continue
    }

    if (message.type === 'tool_result') {
      settleRequest(message)
      continue
    }

    if (message.type === 'load_config') {
      loadAll(message.configPath).catch(error => sendError(error))
      continue
    }

    if (message.type === 'call_tool') {
      callTool(message).catch(error => {
        send({
          type: 'tool_result',
          id: message.id,
          ok: false,
          content: error instanceof Error ? error.message : String(error),
          events: drainSessionEvents(),
        })
      })
      continue
    }
  }
})

process.stdin.on('end', () => process.exit(0))

const configArg = process.argv[2]
if (!configArg) {
  sendError(new Error('usage: node --import tsx/esm index.mjs <cordis-config>'))
  process.exit(1)
}

loadAll(path.resolve(configArg)).catch(error => {
  sendError(error)
  process.exit(1)
})
