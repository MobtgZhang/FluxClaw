// Exercises the real release, SQLite, LiveView, SSE and native tool dispatch.
// Model replies are deterministic local fixtures; no paid credentials are used.
const {_electron: electron} = require('playwright-core')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const http = require('node:http')

async function main() {
  const data = fs.mkdtempSync(path.join(os.tmpdir(), 'fluxclaw-smoke-'))
  fs.writeFileSync(path.join(data, 'config.json'), JSON.stringify({agents:{self_evolve:false,crystallize_skills:false}}))
  let activeStream
  const requests = []
  const server = http.createServer(async (req, res) => {
    let body = ''
    for await (const chunk of req) body += chunk
    const payload = JSON.parse(body)
    requests.push(payload)
    const latest = [...payload.messages].reverse().find(m => m.role === 'user')?.content || ''
    const last = payload.messages.at(-1)
    res.writeHead(200, {'content-type':'text/event-stream'})
    const delta = value => res.write('data: '+JSON.stringify({choices:[{index:0,delta:value}]})+'\n\n')
    const end = () => {res.write('data: [DONE]\n\n');res.end()}
    const call = (id, name, args, index=0) => ({index,id,type:'function',function:{name,arguments:JSON.stringify(args)}})
    if (latest.includes('长文验收')) {
      delta({content: Array.from({length:65},(_,i)=>`第 ${i+1} 段：这是用于检查阅读位置的中文长文。保持清晰排版，方便阅读与验证。\n\n`).join('')})
      activeStream = {delta,end}
    } else if (latest.includes('停止验收')) {
      delta({content:'这是停止前已经产生的内容，应当在刷新后保留。'})
      activeStream = {delta,end}
    } else if (latest.includes('工具验收') && last.role !== 'tool') {
      delta({tool_calls:[call('write-ok','file_write',{path:'result.md',content:'# 交付成果\n\n文件已成功生成。'}),call('write-fail','file_write',{path:'../outside.md',content:'blocked'},1)]})
      end()
    } else if (latest.includes('提问验收') && last.role !== 'tool') {
      delta({tool_calls:[call('ask-confirm','ask_user',{question:'请选择输出语言。'})]})
      end()
    } else {
      delta({content: last.role === 'tool' ? '执行完成，已收到工具结果。' : '测试回答。'})
      end()
    }
  })
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve))
  const env = {...process.env, FLUXCLAW_DESKTOP_DATA:data, OPENAI_API_KEY:'local-smoke-key',
    OPENAI_BASE_URL:`http://127.0.0.1:${server.address().port}/v1`, OPENAI_MODEL:'smoke-model'}
  delete env.ELECTRON_RUN_AS_NODE
  const executablePath = process.env.SMOKE_EXECUTABLE || require('electron')
  const args = process.env.SMOKE_EXECUTABLE ? [] : [path.resolve(__dirname,'..')]
  if (process.env.SMOKE_NO_SANDBOX === '1') args.push('--no-sandbox')
  let app, origin, clipboardOriginal
  try {
    app = await electron.launch({executablePath,args,env,timeout:90000})
    clipboardOriginal = await app.evaluate(({clipboard})=>clipboard.readText())
    const page = await app.firstWindow({timeout:90000})
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.waitForSelector('#workbench-welcome')
    await page.waitForSelector('.phx-connected')
    origin = new URL(page.url()).origin
    assert.equal((await fetch(origin+'/health')).status,403)
    const prefs = await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].webContents.getLastWebPreferences())
    assert.equal(prefs.nodeIntegration,false)
    assert.equal(prefs.contextIsolation,true)
    assert.equal(prefs.sandbox,true)
    const composer = () => page.locator('textarea[phx-hook=ChatComposer]')
    await composer().fill('草稿保留')
    await page.reload();await page.waitForSelector('.phx-connected')
    assert.equal(await composer().inputValue(),'草稿保留')
    await composer().evaluate(el=>el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true})))
    assert.equal(requests.length,0)
    await composer().press('Shift+Enter')
    assert.equal(await composer().inputValue(),'草稿保留\n')
    console.log('Passed: desktop isolation, draft restore, IME and Shift+Enter')
    const send = async text => {await composer().fill(text);await composer().press('Enter')}
    await send('长文验收')
    await page.waitForSelector('#streaming-answer')
    const firstSession = page.url()
    await page.locator('#chat-scroll').evaluate(el=>{el.scrollTop=0;el.dispatchEvent(new Event('scroll'))})
    activeStream.delta({content:'继续增加的正文，不应强制滚动到底部。\n\n'})
    await page.waitForFunction(()=>!document.getElementById('jump-to-latest').classList.contains('hidden'))
    assert.ok(await page.locator('#chat-scroll').evaluate(el=>el.scrollTop<100))
    await page.locator('#jump-to-latest').click()
    await page.waitForFunction(()=>{const e=document.getElementById('chat-scroll');return e.scrollHeight-e.clientHeight-e.scrollTop<100})
    activeStream.delta({content:'\n```elixir\n'+('very_long_variable = "long code"; '.repeat(20))+'\n```\n\n| 项目 | 结果 |\n|---|---|\n| 文件 | 完成 |\n'})
    activeStream.end()
    await page.waitForSelector('#streaming-answer',{state:'detached'})
    await page.waitForSelector('#chat-stop-btn',{state:'detached'})
    console.log('Passed: streaming scroll and Markdown completion')
    await send('工具验收')
    await page.locator('#diff-review-keep').click()
    await page.waitForSelector('.wb-tool-row[data-call-id=write-fail][data-state=error]',{state:'attached'})
    await page.waitForSelector('#chat-stop-btn',{state:'detached'})
    assert.equal(await page.locator('.wb-tool-row').count(),2)
    console.log('Passed: reviewed file write, same-name tool failure and history reload')
    await page.reload();await page.waitForSelector('.phx-connected')
    assert.equal(await page.locator('.wb-tool-row').count(),2)
    await page.locator('.wb-tool-flow > summary').click()
    const failedTool = page.locator('.wb-tool-row[data-call-id=write-fail]')
    await failedTool.locator(':scope > summary').click()
    await failedTool.locator('details').filter({hasText:'完整输出'}).locator('summary').click()
    const output = await failedTool.locator('details').filter({hasText:'完整输出'}).locator('pre').innerText()
    await page.bringToFront()
    await failedTool.getByRole('button',{name:'复制工具输出'}).click()
    await app.evaluate(async ({clipboard}, expected) => {
      const deadline=Date.now()+3000
      while (await clipboard.readText()!==expected) {
        if (Date.now()>deadline) throw new Error('Tool output was not copied')
        await new Promise(resolve=>setTimeout(resolve,25))
      }
    },output)
    await page.locator('#details-toggle').click();await page.locator('#detail-tab-files').click()
    await page.locator('#refresh-artifacts').click()
    await page.waitForSelector('#artifact-files article')
    assert.ok(await page.locator('#artifact-files').innerText().then(t=>t.includes('result.md')))
    const artifact = page.locator('#artifact-files article').filter({hasText:'result.md'})
    const previewReady = app.waitForEvent('window')
    await artifact.getByRole('link',{name:'预览',exact:true}).click()
    const preview = await previewReady
    await preview.waitForLoadState()
    assert.ok((await preview.locator('body').innerText()).includes('文件已成功生成'))
    await preview.close()
    const downloadPath = path.join(data,'downloaded-result.md')
    await app.evaluate(({session}, file) => {
      globalThis.smokeDownload = new Promise((resolve,reject)=> {
        session.fromPartition('persist:fluxclaw').once('will-download',(_event,item)=> {
          item.setSavePath(file)
          item.once('done',(_event,state)=>state==='completed'?resolve(state):reject(new Error(state)))
        })
      })
    },downloadPath)
    await artifact.getByRole('link',{name:'下载',exact:true}).click()
    await app.evaluate(()=>globalThis.smokeDownload)
    assert.ok(fs.readFileSync(downloadPath,'utf8').includes('文件已成功生成'))
    await page.locator('input[type=file]').setInputFiles({name:'notes.txt',mimeType:'text/plain',buffer:Buffer.from('附件测试')})
    await page.locator('#upload-attachments').click()
    await page.waitForFunction(()=>document.querySelector('textarea[phx-hook=ChatComposer]').value.includes('notes.txt'))
    console.log('Passed: artifact browsing and upload')
    await page.keyboard.press('Escape')
    await send('提问验收')
    await page.waitForSelector('#ask-user-form')
    await composer().fill('问答期间的普通草稿')
    await page.locator('#ask-user-text').fill('中文')
    await page.locator('#answer-submit').click()
    await page.waitForSelector('#ask-user-form',{state:'detached'})
    await page.waitForSelector('#chat-stop-btn',{state:'detached'})
    assert.equal(await composer().inputValue(),'问答期间的普通草稿')
    console.log('Passed: ask-user resume preserving ordinary draft')
    await send('停止验收')
    await page.waitForSelector('#streaming-answer')
    await page.locator('#chat-stop-btn').click()
    await page.waitForSelector('#chat-stop-btn',{state:'detached'})
    await page.reload();await page.waitForSelector('.phx-connected')
    assert.ok((await page.locator('#conversation-turns').innerText()).includes('停止前已经产生'))
    await page.waitForSelector('[id^=stopped-]')
    await page.screenshot({path:path.join(data,'desktop.png')})
    await page.setViewportSize({width:390,height:844})
    await page.waitForFunction(()=>document.documentElement.scrollWidth<=innerWidth)
    await page.locator('#navigation-toggle').click()
    await page.waitForSelector('#navigation-toggle[aria-expanded=true]')
    await page.keyboard.press('Tab')
    assert.ok(await page.locator('#sidebar-root').evaluate(el=>el.contains(document.activeElement)))
    await page.keyboard.press('Escape')
    await page.waitForSelector('#navigation-toggle[aria-expanded=false]')
    assert.ok(await page.locator('#navigation-toggle').evaluate(el=>document.activeElement===el))
    await page.locator('#details-toggle').click()
    await page.waitForSelector('#details-toggle[aria-expanded=true]')
    await page.keyboard.press('Tab')
    assert.ok(await page.locator('#sidebar-right').evaluate(el=>el.contains(document.activeElement)))
    await page.keyboard.press('Escape')
    await page.waitForSelector('#details-toggle[aria-expanded=false]')
    assert.ok(await page.locator('#details-toggle').evaluate(el=>document.activeElement===el))
    console.log('Passed: cancellation history and mobile drawer keyboard focus')
    await page.screenshot({path:path.join(data,'mobile.png')})
    await page.evaluate(()=>document.documentElement.dataset.theme='dark')
    await page.screenshot({path:path.join(data,'mobile-dark.png')})
    assert.deepEqual(errors,[])
    console.log(JSON.stringify({data,firstSession,modelRequests:requests.length,unauthorizedStatus:403,passed:true},null,2))
  } finally {
    if (app) {
      if (clipboardOriginal !== undefined) await app.evaluate(({clipboard}, text)=>clipboard.writeText(text),clipboardOriginal).catch(()=>{})
      await app.close()
    }
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve))
  }
  await assert.rejects(fetch(origin+'/health'))
}
main().catch(error=>{console.error(error);process.exitCode=1})
