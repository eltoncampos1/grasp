const DIRECTIONS = {ArrowLeft: "parent", ArrowRight: "child", ArrowUp: "prev", ArrowDown: "next"}

const Keys = {
  mounted() {
    this.onKeydown = (e) => {
      const inField =
        ["INPUT", "TEXTAREA"].includes(e.target.tagName) || document.getElementById("palette")?.open
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

    this.handleEvent("focus", ({id}) => {
      if (id == null) return
      const card = document.getElementById(`card-${id}`)
      card?.scrollIntoView({block: "nearest", inline: "nearest", behavior: "smooth"})
    })
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
}

export default Keys
