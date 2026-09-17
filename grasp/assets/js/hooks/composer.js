// The draft is the browser's. The textarea is `phx-update="ignore"`, so what is being typed
// survives every patch without a round trip, and the hook adds only the two keys a plain
// textarea has not got: save and cancel.
//
// The listener is on the form rather than on the textarea, so a patch that replaces the
// textarea keeps the behaviour, and both keys are stopped before the canvas or the global
// chords see them.
const Composer = {
  mounted() {
    this.el.querySelector("textarea")?.focus()

    this.el.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        this.el.requestSubmit()
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("comment_cancel", {})
      }
    })
  },
}

export default Composer
