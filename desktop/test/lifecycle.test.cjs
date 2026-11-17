const {test} = require('node:test')
const assert = require('node:assert/strict')
const {EventEmitter} = require('node:events')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

// Exercise the main-process lifecycle without opening a native window.
function desktop({ready = async () => true} = {}) {
  const app = new EventEmitter()
  const processStub = new EventEmitter()
  Object.assign(processStub, {argv:['electron', '.', '--dev'], env:{}, platform:'linux'})
  const backend = new EventEmitter()
  Object.assign(backend, {exitCode:null, signals:[]})
  backend.kill = signal => {
    backend.signals.push(signal)
    queueMicrotask(() => backend.emit('exit', null, signal))
    return true
  }
  const windows = [], launches = [], errors = []
  let launchReady, windowReady, appExited
  const started = new Promise(resolve => { launchReady = resolve })
  const loaded = new Promise(resolve => { windowReady = resolve })
  const exited = new Promise(resolve => { appExited = resolve })
  Object.assign(app, {
    requestSingleInstanceLock:() => true,
    whenReady:() => Promise.resolve(),
    getPath:() => '/tmp/fluxclaw-lifecycle',
    quit:() => {
      let prevented = false
      app.emit('before-quit', {preventDefault:() => { prevented = true }})
      if (!prevented) app.exit(0)
    },
    exit:code => appExited(code)
  })
  class BrowserWindow extends EventEmitter {
    constructor(options) {
      super()
      this.options = options
      this.webContents = new EventEmitter()
      this.webContents.setWindowOpenHandler = () => {}
      windows.push(this)
    }
    async loadURL(url) { this.url = url; windowReady(this) }
  }
  const electron = {
    app, BrowserWindow,
    session:{fromPartition:() => ({
      setPermissionRequestHandler:() => {}, setPermissionCheckHandler:() => {},
      webRequest:{onBeforeSendHeaders:() => {}}
    })},
    shell:{}, dialog:{showErrorBox:(_title, message) => errors.push(message)},
    Menu:{buildFromTemplate:value => value, setApplicationMenu:() => {}}
  }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '..', 'main.cjs'), 'utf8'), {
    __dirname:path.resolve(__dirname, '..'), process:processStub, setTimeout, clearTimeout,
    require:name => {
      if (name === 'electron') return electron
      if (name === 'node:fs') return {
        mkdirSync:() => {}, existsSync:() => false, createWriteStream:() => ({end:() => {}})
      }
      if (name === './backend.cjs') return {
        freePort:async () => 43127, health:ready,
        launch:(executable, args, options) => {
          launches.push({executable, args, options})
          launchReady()
          return backend
        }
      }
      return require(name)
    }
  })
  return {app, backend, process:processStub, windows, launches, errors, started, loaded, exited}
}

test('development desktop owns a backend and closing its main window stops it', async () => {
  const runtime = desktop()
  const window = await runtime.loaded
  const launch = runtime.launches[0]
  assert.equal(launch.executable, 'mix')
  assert.deepEqual(Array.from(launch.args), ['fluxclaw.serve'])
  assert.equal(launch.options.env.MIX_ENV, 'dev')
  assert.equal(launch.options.env.FLUXCLAW_DESKTOP_PORT, '43127')
  assert.equal(launch.options.env.FLUXCLAW_DESKTOP_TOKEN.length, 64)
  assert.equal(window.url, 'http://127.0.0.1:43127')
  window.emit('closed')
  assert.equal(await runtime.exited, 0)
  assert.deepEqual(runtime.backend.signals, ['SIGTERM'])
  assert.deepEqual(runtime.errors, [])
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  test(`${signal} during backend startup stops it without creating a window`, async () => {
    let reportHealth
    const healthResult = new Promise(resolve => { reportHealth = resolve })
    const runtime = desktop({ready:() => healthResult})
    await runtime.started
    runtime.process.emit(signal)
    assert.equal(await runtime.exited, 0)
    reportHealth(false)
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(runtime.backend.signals, ['SIGTERM'])
    assert.equal(runtime.windows.length, 0)
    assert.deepEqual(runtime.errors, [])
  })
}
