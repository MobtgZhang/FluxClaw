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
}
try { applyTheme(localStorage.getItem("phx:theme") || "system") } catch (_) {}
window.addEventListener("storage", event => { if (event.key === "phx:theme") applyTheme(event.newValue || "system") })

const Hooks = {
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
        html.setAttribute("data-theme", next)
        localStorage.setItem("phx:theme", next)
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
      this.el.scrollTop = this.el.scrollHeight
    }
  },
  ChatComposer: {
    mounted() {
      this.key = "fluxclaw:draft:" + this.el.dataset.draftKey
      try { this.el.value = sessionStorage.getItem(this.key) || "" } catch (_) {}
      this.resize()
      this.onInput = () => { this.resize(); try { sessionStorage.setItem(this.key, this.el.value) } catch (_) {} }
      this.onKey = event => this.onKeydown(event)
      this.handleEvent("composer-clear", () => { this.el.value = ""; this.onInput() })
      this.handleEvent("composer-attach", ({paths}) => { this.el.value += "\n\n附件路径：\n" + paths.join("\n"); this.onInput(); this.el.focus() })
      this.handleEvent("composer-fill", ({text}) => { this.el.value = text || ""; this.onInput(); this.el.focus() })
      this.el.addEventListener("input", this.onInput)
      this.el.addEventListener("keydown", this.onKey)
    },
    updated() { this.resize() },
    destroyed() {
      this.el.removeEventListener("input", this.onInput)
      this.el.removeEventListener("keydown", this.onKey)
    },
    resize() {
      this.el.style.height = "auto"
      this.el.style.height = Math.min(this.el.scrollHeight, 220) + "px"
    },
    onKeydown(e) {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing || e.keyCode === 229) return
      e.preventDefault()
      if (this.el.closest("form")?.querySelector("#chat-stop-btn, button[type=submit]:disabled")) return
      if (this.el.value.trim()) this.el.closest("form")?.requestSubmit()
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
