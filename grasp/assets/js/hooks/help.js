// The keys-and-gestures dialog. Nothing about it is session state, so it opens and closes
// entirely here: a modal <dialog>, which brings Escape, the focus trap and the backdrop from
// the platform rather than from markup the server would have to keep in step.
const Help = {
  mounted() {
    this.onKeydown = (e) => {
      if (e.key !== "?") return
      // A chord that happens to carry "?" belongs to whoever claims the chord, not to the list.
      if (e.metaKey || e.ctrlKey || e.altKey) return
      // "?" is a character, so a field the reader is typing in keeps it, and the palette's own
      // search box is open over the canvas whenever the palette is.
      if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return
      if (document.getElementById("palette")?.dataset.open === "true") return
      e.preventDefault()
      this.toggle()
    }

    // The toolbar button has no phx-click and the canvas hook claims only the zoom controls,
    // so the click is picked up here, where it bubbles to.
    this.onClickDocument = (e) => {
      const button = e.target.closest?.("#help-toggle")
      if (!button) return
      e.preventDefault()
      // Left holding focus, the button would swallow the Space that pans the canvas.
      button.blur()
      this.toggle()
    }

    // A modal dialog's backdrop is painted by the dialog itself, so a click that lands on the
    // element rather than on anything inside it is a click outside the list.
    this.onClickDialog = (e) => {
      if (e.target === this.el || e.target.closest?.(".help__close")) this.el.close()
    }

    window.addEventListener("keydown", this.onKeydown)
    document.addEventListener("click", this.onClickDocument)
    this.el.addEventListener("click", this.onClickDialog)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("click", this.onClickDocument)
    this.el.removeEventListener("click", this.onClickDialog)
  },

  toggle() {
    if (this.el.open) this.el.close()
    else this.el.showModal()
  },
}

export default Help
