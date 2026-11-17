// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/flux_claw"
import topbar from "../vendor/topbar"
import EasyMDE from "easymde"

const applyTheme = theme => {
  const resolved = theme === "dark" || (theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light"
  document.documentElement.setAttribute("data-theme", resolved)
  document.documentElement.setAttribute("data-theme-preference", theme)
}
try { applyTheme(localStorage.getItem("phx:theme") || "dark") } catch (_) {}
window.addEventListener("storage", event => { if (event.key === "phx:theme") applyTheme(event.newValue || "system") })

window.addEventListener("fluxclaw:set-theme", event => {
  const theme = event.detail.theme
  if (!["dark", "light", "system"].includes(theme)) return
  try { localStorage.setItem("phx:theme", theme) } catch (_) {}
  applyTheme(theme)
})

const positionModelPicker = () => {
  const panel = document.getElementById("composer-model-panel")
  const button = document.getElementById("composer-model")
  if (!panel || !button) return
  const rect = button.getBoundingClientRect()
  const viewport = window.visualViewport
  const height = viewport?.height || window.innerHeight
  const width = viewport?.width || window.innerWidth
  const available = rect.top - 20
  const panelWidth = Math.min(430, width - 28)
  panel.style.left = Math.max(14, Math.min(rect.left, width - panelWidth - 14)) + "px"
  panel.style.width = panelWidth + "px"
  panel.style.bottom = (available < 280 ? 12 : height - rect.top + 8) + "px"
  panel.style.maxHeight = Math.min(620, available < 280 ? height - 24 : available) + "px"
}

const Hooks = {
  WorkbenchShortcuts: {
    mounted() {
      this.onKeyboard = event => {
        const palette = document.getElementById("command-palette")
        const settings = document.getElementById("settings-center")
        const modelPicker = document.getElementById("composer-model-panel")
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
          event.preventDefault()
          this.paletteTrigger = document.activeElement
          this.pushEvent("toggle_palette")
          return
        }
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "n") {
          event.preventDefault()
          if (!palette && !settings) this.pushEvent("new_chat")
          return
        }
        if (event.key === "Escape") {
          const target = modelPicker ? document.getElementById("composer-model") : palette ? this.paletteTrigger : settings ? document.getElementById("sidebar-settings") : null
          requestAnimationFrame(() => target?.focus())
          return
        }
        if (palette && ["ArrowDown", "ArrowUp", "Enter"].includes(event.key)) {
          const results = [...palette.querySelectorAll(".cw-command-result")]
          if (!results.length) return
          const index = results.indexOf(document.activeElement)
          if (event.key === "Enter" && index >= 0) return
          event.preventDefault()
          if (event.key === "Enter") results[0].click()
          else results[event.key === "ArrowDown" ? (index + 1) % results.length : (index <= 0 ? results.length - 1 : index - 1)].focus()
          return
        }
        const modal = palette || settings || modelPicker
        if (modal && event.key === "Tab") {
          const items = [...modal.querySelectorAll("button, a, input, select, textarea, summary")].filter(el => !el.disabled && el.getClientRects().length)
          const first = items[0], last = items[items.length - 1]
          if (event.shiftKey && (document.activeElement === first || !modal.contains(document.activeElement))) { event.preventDefault(); last?.focus() }
          if (!event.shiftKey && (document.activeElement === last || !modal.contains(document.activeElement))) { event.preventDefault(); first?.focus() }
        }
      }
      window.addEventListener("keydown", this.onKeyboard)
      this.settingsObserver = new MutationObserver(() => {
        const modal = document.getElementById("settings-center")
        if (modal && !this.settingsWasOpen) modal.querySelector("#close-settings")?.focus()
        this.settingsWasOpen = !!modal
        const picker = document.getElementById("composer-model-panel")
        positionModelPicker()
        if (picker && !this.pickerWasOpen) picker.querySelector("#composer-model-query")?.focus()
        this.pickerWasOpen = !!picker
      })
      this.settingsObserver.observe(this.el, {childList: true, subtree: true})
    },
    destroyed() {
      window.removeEventListener("keydown", this.onKeyboard)
      this.settingsObserver?.disconnect()
    }
  },
  SidebarContextMenu: {
    mounted() {
      this.el.addEventListener("click", e => {
        e.preventDefault()
        e.stopPropagation()
        const r = this.el.getBoundingClientRect()
        this.pushEvent("open_context_menu", {
          type: this.el.getAttribute("data-menu-type"),
          id: this.el.getAttribute("data-menu-id"),
          top: Math.round(r.top),
          left: Math.round(r.left),
          right: Math.round(r.right),
          bottom: Math.round(r.bottom)
        })
      })
    }
  },
  MarkdownEditor: {
    mounted() {
      const ta = this.el.querySelector("textarea")
      if (!ta) return
      this.form = this.el.closest("form")
      this.mde = new EasyMDE({
        element: ta,
        spellChecker: false,
        status: false,
        minHeight: "280px",
        toolbar: [
          "bold",
          "italic",
          "heading",
          "|",
          "quote",
          "unordered-list",
          "ordered-list",
          "|",
          "link",
          "image",
          "|",
          "preview",
          "side-by-side",
          "fullscreen",
          "|",
          "guide"
        ]
      })
      this.handleEvent("mde_set_value", ({body}) => {
        if (!this.mde) return
        const s = body == null ? "" : String(body)
        this.mde.value(s)
        this.mde.codemirror.refresh()
      })
      this._onSubmit = () => {
        try {
          this.mde?.codemirror?.save()
        } catch (_) {}
      }
      this.form?.addEventListener("submit", this._onSubmit)
    },
    destroyed() {
      this.form?.removeEventListener("submit", this._onSubmit)
      if (this.mde) {
        this.mde.toTextArea()
        this.mde = null
      }
    }
  },
  ThemeToggle: {
    mounted() {
      this.moon = this.el.querySelector('[data-theme-icon="moon"]')
      this.sun = this.el.querySelector('[data-theme-icon="sun"]')
      const sync = () => {
        const dark = document.documentElement.getAttribute("data-theme") === "dark"
        // 深色主题显示月亮，浅色主题显示太阳（表示当前模式）
        this.moon?.classList.toggle("hidden", !dark)
        this.sun?.classList.toggle("hidden", dark)
      }
      sync()
      this.el.addEventListener("click", () => {
        const html = document.documentElement
        const next = html.getAttribute("data-theme") === "dark" ? "light" : "dark"
        applyTheme(next)
        try { localStorage.setItem("phx:theme", next) } catch (_) {}
        sync()
      })
    }
  },
  ChatScroll: {
    mounted() {
      this.following = true
      this.jump = document.getElementById("jump-to-latest")
      this.onScroll = () => {
        this.following = this.el.scrollHeight - this.el.clientHeight - this.el.scrollTop < 100
        if (this.following) this.jump?.classList.add("hidden")
      }
      this.onJump = () => { this.following = true; this.scrollBottom(); this.jump?.classList.add("hidden") }
      this.el.addEventListener("scroll", this.onScroll, {passive: true})
      this.jump?.addEventListener("click", this.onJump)
      this.observer = new ResizeObserver(() => this.onContentChange())
      this.observer.observe(this.el.firstElementChild)
      this.scrollBottom()
      const evName = this.el.getAttribute("data-external-link-event") || "external_link_click"
      this._externalLinkHandler = e => {
        const a = e.target.closest?.("a[href]")
        if (!a || !a.href) return
        try {
          const u = new URL(a.href, window.location.origin)
          if (u.protocol === "http:" || u.protocol === "https:") {
            if (u.host === window.location.host) return
            e.preventDefault()
            e.stopPropagation()
            this.pushEvent(evName, {
              url: a.href,
              title: (a.textContent || "").trim().slice(0, 300)
            })
          }
        } catch (_) {}
      }
      this.el.addEventListener("click", this._externalLinkHandler)
      this.handleEvent("open_external", ({url}) => {
        if (url && typeof url === "string") {
          window.open(url, "_blank", "noopener,noreferrer")
        }
      })
      this.handleEvent("clipboard-copy", ({text}) => {
        const t = text == null ? "" : String(text)
        if (t) navigator.clipboard.writeText(t).catch(() => {})
      })
      this.handleEvent("download-text", ({filename, text, mime}) => {
        const t = text == null ? "" : String(text)
        const blob = new Blob([t], {type: mime || "text/plain;charset=utf-8"})
        const url = URL.createObjectURL(blob)
        const a = document.createElement("a")
        a.href = url
        a.download = filename || "download.txt"
        document.body.appendChild(a)
        a.click()
        a.remove()
        URL.revokeObjectURL(url)
      })
    },
    destroyed() {
      this.el.removeEventListener("scroll", this.onScroll)
      this.jump?.removeEventListener("click", this.onJump)
      this.observer?.disconnect()
      if (this._externalLinkHandler) {
        this.el.removeEventListener("click", this._externalLinkHandler)
      }
    },
    updated() { this.onContentChange() },
    onContentChange() {
      if (this.following) {
        requestAnimationFrame(() => this.scrollBottom())
      } else {
        this.jump?.classList.remove("hidden")
      }
    },
    scrollBottom() {
      this.el.scrollTop = this.el.querySelector("#workbench-welcome") ? 0 : this.el.scrollHeight
    }
  },
  ChatComposer: {
    mounted() {
      this.key = "fluxclaw:draft:" + this.el.dataset.draftKey
      try { this.el.value = sessionStorage.getItem(this.key) || "" } catch (_) {}
      this.resize()
      this.form = this.el.closest("form")
      this.onInput = () => { this.resize(); this.syncSend(); try { sessionStorage.setItem(this.key, this.el.value) } catch (_) {} }
      this.onKey = event => this.onKeydown(event)
      this.handleEvent("composer-clear", () => { this.el.value = ""; this.onInput() })
      this.handleEvent("composer-fill", ({text}) => { this.el.value = text || ""; this.onInput(); this.el.focus() })
      this.el.addEventListener("input", this.onInput)
      this.el.addEventListener("keydown", this.onKey)
      this.onPaste = event => {
        const files = [...(event.clipboardData?.files || [])]
        if (!files.length || this.form.dataset.locked === "true") return
        event.preventDefault()
        this.upload("attachments", files)
      }
      this.el.addEventListener("paste", this.onPaste)
      this.onDragOver = event => {
        if (event.dataTransfer?.types.includes("Files") && this.form.dataset.locked !== "true") {
          event.preventDefault()
          this.form.classList.add("is-dragging")
        }
      }
      this.onDragLeave = event => { if (!this.form.contains(event.relatedTarget)) this.form.classList.remove("is-dragging") }
      this.onDrop = () => this.form.classList.remove("is-dragging")
      this.form.addEventListener("dragover", this.onDragOver)
      this.form.addEventListener("dragleave", this.onDragLeave)
      this.form.addEventListener("drop", this.onDrop)
      this.onLayout = () => this.positionPicker()
      this.layoutObserver = new ResizeObserver(this.onLayout)
      this.layoutObserver.observe(this.form)
      window.addEventListener("resize", this.onLayout)
      window.visualViewport?.addEventListener("resize", this.onLayout)
      this.positionPicker()
      this.sendObserver = new MutationObserver(() => this.syncSend())
      this.sendObserver.observe(this.form, {attributes: true, childList: true, subtree: true, attributeFilter: ["disabled", "data-locked", "data-upload-blocked", "data-attachment-count"]})
      this.syncSend()
    },
    updated() { this.resize(); this.syncSend() },
    syncSend() {
      const button = this.form?.querySelector("#chat-send-btn")
      if (button) {
        const disabled = this.form.dataset.locked === "true" || this.form.dataset.uploadBlocked === "true" || (!this.el.value.trim() && Number(this.form.dataset.attachmentCount) === 0)
        if (button.disabled !== disabled) button.disabled = disabled
      }
    },
    destroyed() {
      this.el.removeEventListener("input", this.onInput)
      this.el.removeEventListener("keydown", this.onKey)
      this.el.removeEventListener("paste", this.onPaste)
      this.form?.removeEventListener("dragover", this.onDragOver)
      this.form?.removeEventListener("dragleave", this.onDragLeave)
      this.form?.removeEventListener("drop", this.onDrop)
      this.sendObserver?.disconnect()
      this.layoutObserver?.disconnect()
      window.removeEventListener("resize", this.onLayout)
      window.visualViewport?.removeEventListener("resize", this.onLayout)
    },
    positionPicker() { positionModelPicker() },
    resize() {
      this.el.style.height = "auto"
      this.el.style.height = Math.min(this.el.scrollHeight, 220) + "px"
    },
    onKeydown(e) {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing || e.keyCode === 229) return
      e.preventDefault()
      if (this.el.closest("form")?.querySelector("#chat-stop-btn, button[type=submit]:disabled")) return
      this.el.closest("form")?.requestSubmit()
    }
  }

}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
window.addEventListener("fluxclaw:copy", event => {
  navigator.clipboard.writeText(event.detail.text || "").catch(() => {})
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


// Preserve focus when a drawer closes; keep keyboard navigation inside mobile drawers.
let drawerTrigger = null
const drawerVisible = element => element && getComputedStyle(element).display !== "none" && element.getBoundingClientRect().right > 0 && element.getBoundingClientRect().left < innerWidth
window.addEventListener("click", event => {
  if (event.target.closest("[phx-click=toggle_sidebar], [phx-click=toggle_right], [phx-click=set_right_tab]")) drawerTrigger = event.target.closest("button")
})
window.addEventListener("keydown", event => {
  if (document.getElementById("command-palette") || document.getElementById("settings-center")) return
  if (event.key === "Escape" && drawerTrigger) { requestAnimationFrame(() => drawerTrigger?.focus()); return }
  if (event.key !== "Tab") return
  const drawer = [document.getElementById("sidebar-right"), document.getElementById("sidebar-root")].find(element => drawerVisible(element) && getComputedStyle(element).position === "fixed")
  if (!drawer) return
  const focusable = [...drawer.querySelectorAll("button, a, input, textarea, select, summary")].filter(element => !element.disabled && element.getClientRects().length)
  const first = focusable[0], last = focusable[focusable.length - 1]
  if (!first) return
  if (event.shiftKey && (document.activeElement === first || !drawer.contains(document.activeElement))) { event.preventDefault(); last.focus() }
  if (!event.shiftKey && (document.activeElement === last || !drawer.contains(document.activeElement))) { event.preventDefault(); first.focus() }
})
