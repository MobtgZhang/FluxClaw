const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const net = require('node:net')
const http = require('node:http')
const {spawn} = require('node:child_process')

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)) })
  })
}
function backendEnvironment(data, port, token, python) {
  fs.mkdirSync(data, {recursive:true, mode:0o700})
  const secretFile = path.join(data, 'secret')
  if (!fs.existsSync(secretFile)) fs.writeFileSync(secretFile, crypto.randomBytes(64).toString('base64'), {mode:0o600, flag:'wx'})
  const env = {...process.env, PHX_SERVER:'true', PHX_HOST:'127.0.0.1', PORT:String(port), FLUXCLAW_DESKTOP:'1',
    FLUXCLAW_DESKTOP_TOKEN:token, SECRET_KEY_BASE:fs.readFileSync(secretFile, 'utf8'),
    DATABASE_PATH:path.join(data,'fluxclaw.db'), FLUXCLAW_CONFIG_PATH:path.join(data,'config.json'),
    FLUXCLAW_CACHE_ROOT:path.join(data,'cache'), FLUX_CLAW_SANDBOX:path.join(data,'workspaces'),
    RELEASE_TMP:path.join(data,'runtime'), RELEASE_DISTRIBUTION:'none', ERL_FLAGS:'+S 4:4',
    ELECTRON_RUN_AS_NODE:'1', FLUXCLAW_NODE:process.execPath}
  if (python) env.FLUXCLAW_PYTHON = python
  return env
}
function health(url, token) {
  return new Promise(resolve => {
    const req = http.get(url + '/health', {headers:{'x-fluxclaw-desktop':token}, timeout:1000}, res => {
      let body = ''; res.on('data', chunk => {body += chunk}); res.on('end', () => {
        try { const data = JSON.parse(body); resolve(res.statusCode === 200 && data.app === 'fluxclaw') } catch {resolve(false)}
      })
    }); req.on('error', () => resolve(false)); req.on('timeout', () => req.destroy())
  })
}
function launch(executable, args, options, log) {
  const child = spawn(executable, args, {...options, stdio:['ignore','pipe','pipe'], windowsHide:true})
  child.stdout.on('data', data => log.write(data)); child.stderr.on('data', data => log.write(data))
  return child
}
function waitForExit(child, timeout=60000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {child.kill(); reject(new Error('Backend migration timed out'))}, timeout)
    child.once('error', err => {clearTimeout(timer); reject(err)})
    child.once('exit', code => {clearTimeout(timer); code === 0 ? resolve() : reject(new Error('Backend migration failed ('+code+')'))})
  })
}
function isLocalNavigation(target, origin) {
  try {return new URL(target).origin === new URL(origin).origin} catch {return false}
}
module.exports = {freePort, backendEnvironment, health, launch, waitForExit, isLocalNavigation}
