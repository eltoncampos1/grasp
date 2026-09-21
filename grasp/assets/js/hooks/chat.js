// The transcript is server state, so the hook only does the five things a render cannot:
// keep the log pinned to the newest entry, empty the input once its value has been sent,
// put the caret in that input the moment the panel opens, turn a click on a function link
// into the event that opens its card, and count the seconds a live run has been going.
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
// That last one is why an answer's markup carries no event bindings of its own. An answer
// is written by the model, and the sanitiser therefore strips every `phx-` attribute from
// it; a function link is a button carrying `data-fn`, and this hook is the only thing that
// maps it to an event, so the model can name an id but never an event.
//
// Nothing is cached across patches: a node held from `mounted()` is a node a later patch
// could have replaced, and writing to the detached original fails silently.
const Chat = {
  mounted() {
    // Delegated from the panel so a patch that replaces the form keeps the behaviour, and
    // deferred so the value is still there when LiveView serialises the submit.
    this.el.addEventListener("submit", () => {
      window.setTimeout(() => {
        const input = this.input()
        if (input) input.value = ""
      }, 0)
    })

    // Delegated for the same reason: every patch rewrites the transcript's markup.
    this.el.addEventListener("click", (event) => {
      const link = event.target.closest(".msg .fn[data-fn]")
      if (link) this.pushEvent("open_root", { id: link.dataset.fn })
    })

    this.wasOpen = false
    this.timer = null
    this.scrollToBottom()
    this.focusWhenOpened()
    this.tick()
  },

  updated() {
    this.scrollToBottom()
    this.focusWhenOpened()
    this.tick()
  },

  destroyed() {
    this.stopTicking()
  },

  input() {
    return this.el.querySelector("#chat-prompt")
  },

  scrollToBottom() {
    const log = this.el.querySelector("#chat-log")
    if (log) log.scrollTop = log.scrollHeight
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
