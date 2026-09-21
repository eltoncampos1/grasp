// The transcript is server state, so the hook only does what a render cannot: keep the log
// pinned to the newest entry while the reader is at the bottom of it, grow the prompt box
// to what is being typed and send it on Enter, recall what was sent before, empty the box
// once its value has been sent, put the caret in it the moment the panel opens, turn a
// click on a function link into the event that opens its card, copy a message or a fence to
// the clipboard, and count the seconds a live run has been going.
//
// The elapsed seconds are counted here rather than rendered because a render per second
// is a patch per second on a panel that is already being patched by the run itself. The
// server publishes the millisecond the run started, as `data-elapsed-from`; the timer
// reads it and stops itself once the attribute is gone, which is how a finished run ends
// the counting without anything telling the client that it has. The count is a stopwatch,
// so a part-second reads as the second it is still in. It compares a server wall-clock
// reading against the browser's own, which agree on a viewer served from this machine and
// leave the count pinned at 0s for a client whose clock is behind.
//
// Scrolling follows the reader rather than the output: the log is pinned to its newest line
// only while the reader is within a couple of lines of the bottom, and a run that writes
// while they are reading further up leaves them where they are and offers the pill instead.
//
// Function links are why an answer's markup carries no event bindings of its own. An answer
// is written by the model, and the sanitiser therefore strips every `phx-` attribute from
// it; a function link is a button carrying `data-fn`, and this hook is the only thing that
// maps it to an event, so the model can name an id but never an event. A fence's copy
// button comes from here for the same reason: the fence is rendered from model output, so
// the button is added to the DOM after each patch rather than written into that output.
//
// Nothing is cached across patches: a node held from `mounted()` is a node a later patch
// could have replaced, and writing to the detached original fails silently.
const BOTTOM_PX = 24
const HISTORY = 20
const COPIED_MS = 1500
const MAX_ROWS = 6

const Chat = {
  mounted() {
    // Delegated from the panel so a patch that replaces the form keeps the behaviour, and
    // deferred so the value is still there when LiveView serialises the submit.
    this.el.addEventListener("submit", () => {
      const input = this.input()
      this.remember(input && input.value)
      this.atBottom = true

      window.setTimeout(() => {
        const input = this.input()
        if (input) {
          input.value = ""
          this.grow(input)
        }
        this.scrollToBottom()
      }, 0)
    })

    // Delegated for the same reason: every patch rewrites the transcript's markup.
    this.el.addEventListener("click", (event) => {
      const link = event.target.closest(".msg .fn[data-fn]")
      if (link) this.pushEvent("open_root", { id: link.dataset.fn })

      const copy = event.target.closest(".copy")
      if (copy) this.copy(copy)

      if (event.target.closest("#chat-jump")) {
        this.atBottom = true
        this.scrollToBottom()
        this.showPill()
      }
    })

    this.el.addEventListener("keydown", (event) => {
      if (event.target.id === "chat-prompt") this.keydown(event)
    })

    this.el.addEventListener("input", (event) => {
      if (event.target.id === "chat-prompt") {
        this.recalled = null
        this.grow(event.target)
      }
    })

    // A scroll event does not bubble, so it is caught on the way down instead.
    this.el.addEventListener(
      "scroll",
      (event) => {
        if (event.target.id !== "chat-log") return
        this.atBottom = this.isAtBottom(event.target)
        this.showPill()
      },
      true,
    )

    this.wasOpen = false
    this.timer = null
    this.atBottom = true
    this.history = []
    this.recalled = null
    this.at = null
    this.scrollToBottom()
    this.focusWhenOpened()
    this.fenceButtons()
    this.tick()
  },

  updated() {
    if (this.atBottom) this.scrollToBottom()
    this.showPill()
    this.focusWhenOpened()
    this.fenceButtons()
    this.tick()
  },

  destroyed() {
    this.stopTicking()
  },

  input() {
    return this.el.querySelector("#chat-prompt")
  },

  log() {
    return this.el.querySelector("#chat-log")
  },

  scrollToBottom() {
    const log = this.log()
    if (log) log.scrollTop = log.scrollHeight
  },

  isAtBottom(log) {
    return log.scrollHeight - log.scrollTop - log.clientHeight <= BOTTOM_PX
  },

  // The pill offers the way down to a reader who has scrolled away from it. The server
  // renders it hidden, so every patch hides it again and this says whether it stays that
  // way.
  showPill() {
    const pill = this.el.querySelector("#chat-jump")
    if (pill) pill.hidden = this.atBottom
  },

  // Enter sends, because the box is a prompt before it is a text editor; a line break is
  // the shifted one. ArrowUp on an empty box recalls what was sent last, and pressing it
  // again on a recalled prompt steps further back, so a question can be reworded rather
  // than retyped. A composition in progress owns its own Enter.
  keydown(event) {
    const input = event.target

    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      if (input.form) input.form.requestSubmit()
      return
    }

    if (event.key === "ArrowUp") {
      const from = this.recallFrom(input.value)
      if (from === null) return

      event.preventDefault()
      input.value = this.history[from]
      this.recalled = input.value
      this.at = from
      this.grow(input)
      input.setSelectionRange(input.value.length, input.value.length)
    }
  },

  recallFrom(value) {
    if (value === "") return this.history.length ? this.history.length - 1 : null
    if (value === this.recalled && this.at > 0) return this.at - 1
    return null
  },

  // A prompt resent as it was recalled is the entry already at the end of the history, and
  // pushing it again would leave ArrowUp stepping over the same words twice.
  remember(prompt) {
    if (!prompt || !prompt.trim()) return
    if (this.history[this.history.length - 1] !== prompt) {
      this.history = this.history.concat([prompt]).slice(-HISTORY)
    }
    this.recalled = null
  },

  // The box is one line until what is in it needs more, and stops growing at six so the
  // transcript is never pushed off the panel by a long prompt.
  grow(input) {
    const style = window.getComputedStyle(input)
    const line = parseFloat(style.lineHeight) || 18
    const around =
      input.offsetHeight -
      input.clientHeight +
      parseFloat(style.paddingBlockStart || 0) +
      parseFloat(style.paddingBlockEnd || 0)

    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, line * MAX_ROWS + around)}px`
  },

  // What the reader sees, not what the markup says: a rendered answer is Markdown, so its
  // text is read off the DOM. The copy buttons inside it are hidden for the reading, since
  // `innerText` would otherwise hand back their labels as part of the answer.
  copy(button) {
    const target = button.dataset.copy === "pre" ? button.closest("pre") : button.closest(".msg")
    if (!target) return

    const buttons = Array.from(target.querySelectorAll(".copy"))
    buttons.forEach((each) => (each.hidden = true))
    const text = target.innerText
    buttons.forEach((each) => (each.hidden = false))

    if (!navigator.clipboard) return

    navigator.clipboard.writeText(text).then(() => {
      const label = button.textContent
      button.textContent = "Copied"
      window.setTimeout(() => {
        if (button.isConnected) button.textContent = label
      }, COPIED_MS)
    })
  },

  // Only fences that have not got a button, and none inside a message still being
  // streamed: the selector is what makes a patch that changed nothing cost no DOM writes,
  // and a partial message's markup is rewritten on every delta, so a button put in it
  // would go with the next one.
  fenceButtons() {
    const fences = `#chat-log .msg:not([data-partial="true"]) pre.fence:not(:has(> button.copy))`

    this.el.querySelectorAll(fences).forEach((fence) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "copy"
      button.dataset.copy = "pre"
      button.textContent = "Copy"
      fence.prepend(button)
    })
  },

  // Only on the opening patch: later ones land while the user is typing here or reading a
  // card, and taking focus back on each of them would fight whatever they are doing.
  focusWhenOpened() {
    const open = !this.el.hidden
    if (open && !this.wasOpen) this.input()?.focus()
    this.wasOpen = open
  },

  tick() {
    const span = this.el.querySelector("[data-elapsed-from]")
    if (!span) return this.stopTicking()

    const from = Number(span.dataset.elapsedFrom)
    if (Number.isFinite(from)) {
      const seconds = Math.max(0, Math.floor((Date.now() - from) / 1000))
      span.textContent = `${seconds}s`
    }

    if (!this.timer) this.timer = window.setInterval(() => this.tick(), 1000)
  },

  stopTicking() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  },
}

export default Chat
