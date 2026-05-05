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

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const PANE_HEIGHT_KEY = "cham:pane-height"
const PANE_HEIGHT_MIN = 120
const PANE_HEIGHT_DEFAULT = 300

const applyPaneHeight = (px) => {
  const max = Math.floor(window.innerHeight * 0.85)
  const clamped = Math.max(PANE_HEIGHT_MIN, Math.min(max, px))
  document.documentElement.style.setProperty("--pane-height", `${clamped}px`)
  return clamped
}

const stored = parseInt(localStorage.getItem(PANE_HEIGHT_KEY), 10)
applyPaneHeight(Number.isFinite(stored) ? stored : PANE_HEIGHT_DEFAULT)

const Hooks = {}
Hooks.PaneResize = {
  mounted() {
    const handle = this.el.querySelector("[data-resize-handle]")
    if (!handle) return

    const onPointerDown = (e) => {
      e.preventDefault()
      handle.setPointerCapture(e.pointerId)
      document.body.style.cursor = "ns-resize"
      document.body.style.userSelect = "none"

      if (!this.el.querySelector(".pane-body")) {
        const firstTab = this.el.querySelector(".pane-tab")
        if (firstTab) firstTab.click()
      }

      const onMove = (ev) => {
        const fromBottom = window.innerHeight - ev.clientY
        applyPaneHeight(fromBottom)
      }
      const onUp = () => {
        handle.releasePointerCapture(e.pointerId)
        document.body.style.cursor = ""
        document.body.style.userSelect = ""
        handle.removeEventListener("pointermove", onMove)
        handle.removeEventListener("pointerup", onUp)
        const current = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--pane-height"), 10)
        if (Number.isFinite(current)) localStorage.setItem(PANE_HEIGHT_KEY, String(current))
      }
      handle.addEventListener("pointermove", onMove)
      handle.addEventListener("pointerup", onUp)
    }
    handle.addEventListener("pointerdown", onPointerDown)
    this._cleanup = () => handle.removeEventListener("pointerdown", onPointerDown)
  },
  destroyed() {
    if (this._cleanup) this._cleanup()
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
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

