const {app, BrowserWindow, session, shell, dialog, Menu} = require('electron')
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const {freePort, backendEnvironment, health, launch, waitForExit, isLocalNavigation} = require('./backend.cjs')
let backend, window, log, quitting = false
if (process.env.FLUXCLAW_DESKTOP_DATA) {
  const data = path.resolve(process.env.FLUXCLAW_DESKTOP_DATA)
  fs.mkdirSync(data, {recursive:true, mode:0o700})
  app.setPath('userData', data)
}
const locked = app.requestSingleInstanceLock()
if (!locked) app.quit()
else {
  app.on('second-instance', () => { if (window) {if (window.isMinimized()) window.restore(); window.show(); window.focus()} })
  app.whenReady().then(start).catch(fail)
}
async function start() {
  const data = app.getPath('userData')
  fs.mkdirSync(data, {recursive:true, mode:0o700})
  const logPath = path.join(data, 'backend.log')
  if (fs.existsSync(logPath) && fs.statSync(logPath).size > 5_000_000) fs.renameSync(logPath, logPath+'.previous')
  log = fs.createWriteStream(logPath, {flags:'a', mode:0o600})
  const token = crypto.randomBytes(32).toString('hex')
  const dev = process.argv.includes('--dev') && !app.isPackaged
  let origin
  if (dev) origin = 'http://127.0.0.1:4000'
  else {
    const root = app.isPackaged ? process.resourcesPath : path.join(__dirname,'resources')
    const release = path.join(root,'backend','bin', process.platform === 'win32' ? 'flux_claw.bat' : 'flux_claw')
    const python = path.join(root, 'python', process.platform === 'win32' ? 'python.exe' : 'bin/python3')
    if (!fs.existsSync(release)) throw new Error('Backend release missing. Run npm run prepare:backend before starting.')
    const port = await freePort()
    const env = backendEnvironment(data, port, token, fs.existsSync(python) ? python : undefined)
    fs.mkdirSync(env.RELEASE_TMP,{recursive:true})
    const options = {cwd:data, env}
    // The Windows release launcher is a batch script from mix release.
    if (process.platform === 'win32') options.shell = true
    await waitForExit(launch(release,['eval','FluxClaw.Release.migrate()'], options, log))
    backend = launch(release,['start'], options, log)
    backend.on('error', fail)
    backend.on('exit', code => { if (!quitting) fail(new Error('Backend exited ('+code+'). See '+logPath)) })
    origin = 'http://127.0.0.1:'+port
  }
  const partition = session.fromPartition('persist:fluxclaw')
  partition.setPermissionRequestHandler((wc,permission,callback) =>
    callback(permission === 'clipboard-sanitized-write' && isLocalNavigation(wc.getURL(),origin)))
  partition.setPermissionCheckHandler((_wc,permission,requestingOrigin) =>
    permission === 'clipboard-sanitized-write' && isLocalNavigation(requestingOrigin,origin))
  partition.webRequest.onBeforeSendHeaders({urls:[origin+'/*', origin.replace('http:','ws:')+'/*']}, (details, callback) => {
    details.requestHeaders['x-fluxclaw-desktop'] = token
    callback({requestHeaders:details.requestHeaders})
  })
  if (!dev) {
    const deadline = Date.now()+60000
    while (!(await health(origin,token))) {
      if (Date.now() > deadline || backend.exitCode !== null) throw new Error('Backend did not become ready. See '+logPath)
      await new Promise(resolve => setTimeout(resolve,250))
    }
  }
  window = new BrowserWindow({width:1360,height:900,minWidth:390,minHeight:600,show:false,backgroundColor:'#FAF9F6', title:'FluxClaw',
    webPreferences:{session:partition,contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true,allowRunningInsecureContent:false}})
  window.webContents.setWindowOpenHandler(({url}) => {
    if (isLocalNavigation(url,origin) && new URL(url).pathname.startsWith('/artifacts/')) {
      return {action:'allow',overrideBrowserWindowOptions:{width:900,height:700,autoHideMenuBar:true,
        webPreferences:{session:partition,contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true}}}
    }
    openExternal(url); return {action:'deny'}
  })
  window.webContents.on('did-create-window', child => {
    child.webContents.setWindowOpenHandler(({url}) => {openExternal(url);return {action:'deny'}})
    child.webContents.on('will-navigate',(event,url)=>{if (!isLocalNavigation(url,origin)) {event.preventDefault();openExternal(url)}})
    child.webContents.on('will-attach-webview',event=>event.preventDefault())
  })
  window.webContents.on('will-navigate', (event,url) => {if (!isLocalNavigation(url,origin)) {event.preventDefault();openExternal(url)}})
  window.webContents.on('will-attach-webview', event => event.preventDefault())
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{role:'appMenu'}] : []),
    {label:'文件',submenu:[{label:'新建任务',accelerator:'CmdOrCtrl+N',click:()=>window.loadURL(origin)}, {label:'打开数据目录',click:()=>shell.openPath(data)}, {type:'separator'},{role:'quit'}]},
    {role:'editMenu'}, {label:'视图',submenu:[{role:'reload'},{role:'togglefullscreen'},{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'},...(!app.isPackaged?[{role:'toggleDevTools'}]:[])]}
  ]))
  window.once('ready-to-show', () => window.show())
  window.on('closed', () => {window=null;app.quit()})
  await window.loadURL(origin)
}
function openExternal(url) { try {if (['https:','http:'].includes(new URL(url).protocol)) shell.openExternal(url)} catch {} }
function fail(error) {
  if (quitting) return
  dialog.showErrorBox('FluxClaw 启动失败',error.message+'\n\n后端日志位于应用数据目录的 backend.log。')
  app.quit()
}
app.on('before-quit', event => {
  if (!quitting && backend && backend.exitCode === null) {
    event.preventDefault();quitting=true
    const timer=setTimeout(()=>{backend.kill('SIGKILL');app.exit(0)},5000)
    backend.once('exit',()=>{clearTimeout(timer);log?.end();app.exit(0)})
    backend.kill('SIGTERM')
  } else quitting=true
})
app.on('window-all-closed',()=>app.quit())
