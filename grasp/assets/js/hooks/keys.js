const DIRECTIONS = {ArrowLeft: "parent", ArrowRight: "child", ArrowUp: "prev", ArrowDown: "next"}

const Keys = {
  mounted() {
    this.onKeydown = (e) => {
      if (document.getElementById("palette")?.dataset.open === "true") return

      // The toolbar advertises Cmd+I as a toggle, so it has to reach the prompt it just
      // focused; every other chord stays out of a field the user is typing in.
      const chatToggle = (e.metaKey || e.ctrlKey) && e.key === "i"
      if (["INPUT", "TEXTAREA"].includes(e.target.tagName) && !chatToggle) return

      // Cmd+= and Cmd+- stay with the browser; only the two chords the canvas claims are taken.
      if (e.metaKey || e.ctrlKey) {
        // Cmd+M is the macOS "minimise window" shortcut and a browser may act on it before the
        // page ever sees the key, so Cmd+\ is the fallback that always gets through.
        if (e.key === "m" || e.key === "\\") {
          e.preventDefault()
          this.pushEvent("toggle_sidebar", {})
        } else if (e.key === "i") {
          e.preventDefault()
          this.pushEvent("chat_toggle", {})
        } else if (e.key === "0") {
          e.preventDefault()
          // The zoom lives entirely in the Canvas hook, so this is hook to hook through the DOM
          // rather than a round trip to the server.
          window.dispatchEvent(new CustomEvent("grasp:zoom-reset"))
        }
        return
      }
      if (e.altKey) return

      if (DIRECTIONS[e.key]) {
        e.preventDefault()
        this.pushEvent("move_focus", {dir: DIRECTIONS[e.key]})
      } else if (e.key === "x") {
        this.pushEvent("close_focused", {})
      } else if (e.key === "c") {
        this.pushEvent("collapse_focused", {})
      }
    }
    window.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
}

export default Keys
