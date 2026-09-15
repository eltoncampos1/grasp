const Palette = {
  mounted() {
    this.dialog = this.el
    this.input = this.el.querySelector("input[name=q]")
    this.results = this.el.querySelector("#palette-results")

    this.onKeydownWindow = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.open()
      }
    }
    window.addEventListener("keydown", this.onKeydownWindow)

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        this.move(e.key === "ArrowDown" ? 1 : -1)
      } else if (e.key === "Enter") {
        e.preventDefault()
        const selected = this.results.querySelector("li[aria-selected='true']")
        if (selected) this.pushEvent("palette_open", {id: selected.dataset.id, child: e.shiftKey})
      }
    })

    this.el.addEventListener("click", (e) => {
      if (e.target === this.dialog) this.dialog.close()
    })

    this.handleEvent("palette:close", () => this.dialog.close())
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydownWindow)
  },

  open() {
    if (!this.dialog.open) this.dialog.showModal()
    this.input.value = ""
    this.input.focus()
  },

  move(delta) {
    const items = Array.from(this.results.querySelectorAll("li"))
    if (items.length === 0) return
    const current = items.findIndex((li) => li.getAttribute("aria-selected") === "true")
    const next = Math.min(items.length - 1, Math.max(0, current + delta))
    items.forEach((li, i) => li.setAttribute("aria-selected", String(i === next)))
    items[next].scrollIntoView({block: "nearest"})
  },
}

export default Palette
