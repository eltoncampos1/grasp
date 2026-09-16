// The transcript is server state, so the hook only does the three things a render cannot:
// keep the log pinned to the newest entry, empty the uncontrolled input once its value has
// been sent, and put the caret in that input the moment the panel opens.
const Chat = {
  mounted() {
    this.input = this.el.querySelector("#chat-prompt")
    this.log = this.el.querySelector("#chat-log")

    // Delegated from the panel so a patch that replaces the form keeps the behaviour, and
    // deferred so the value is still there when LiveView reads it off the submit.
    this.el.addEventListener("submit", () => {
      window.setTimeout(() => {
        this.input.value = ""
      }, 0)
    })

    this.wasOpen = false
    this.scrollToBottom()
    this.focusWhenOpened()
  },

  updated() {
    this.scrollToBottom()
    this.focusWhenOpened()
  },

  scrollToBottom() {
    if (this.log) this.log.scrollTop = this.log.scrollHeight
  },

  // Only on the opening patch: later ones land while the user is typing here or reading a
  // card, and taking focus back on each of them would fight whatever they are doing.
  focusWhenOpened() {
    const open = !this.el.hidden
    if (open && !this.wasOpen) this.input.focus()
    this.wasOpen = open
  },
}

export default Chat
