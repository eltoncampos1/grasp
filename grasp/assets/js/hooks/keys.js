const DIRECTIONS = {ArrowLeft: "parent", ArrowRight: "child", ArrowUp: "prev", ArrowDown: "next"}

const Keys = {
  mounted() {
    this.onKeydown = (e) => {
      const inField =
        ["INPUT", "TEXTAREA"].includes(e.target.tagName) ||
        document.getElementById("palette")?.dataset.open === "true"
      if (inField || e.metaKey || e.ctrlKey || e.altKey) return

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
