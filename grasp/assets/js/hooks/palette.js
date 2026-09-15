const Palette = {
  mounted() {
    this.input = this.el.querySelector("input[name=q]")
    this.wasOpen = false

    this.onKeydownWindow = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key?.toLowerCase() === "k") {
        e.preventDefault()
        this.pushEvent("palette_show", {})
      }
    }
    window.addEventListener("keydown", this.onKeydownWindow)

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("palette_hide", {})
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        this.pushEvent("palette_move", {delta: e.key === "ArrowDown" ? 1 : -1})
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.pushEvent("palette_choose", {child: e.shiftKey})
      }
    })

    this.focusWhenOpened()
  },

  updated() {
    this.focusWhenOpened()
    this.el.querySelector("li[aria-selected='true']")?.scrollIntoView({block: "nearest"})
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydownWindow)
  },

  // Focus is taken once per opening: on later patches the caret belongs to whatever the
  // user is typing in, so stealing it back would undo their edits.
  focusWhenOpened() {
    const open = this.el.dataset.open === "true"

    if (open && !this.wasOpen && document.activeElement !== this.input) {
      this.input.focus()
      this.input.select()
    }

    this.wasOpen = open
  },
}

export default Palette
