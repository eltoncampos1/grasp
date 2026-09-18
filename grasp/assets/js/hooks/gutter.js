// A press on a line number that travels to another line comments on the range between them.
// The hook is mounted on the card body, which is the only element that holds every line of
// one card and one side at a time.
//
// The press is stopped where it is seen, so the canvas hook below never reads it: a plain
// press inside a card is already no gesture of the canvas's, but a Ctrl-press on a card is
// how a card is dragged, and that one has to go on reaching it — so a press carrying Ctrl or
// Meta is left alone here and no range begins.
//
// The selection is the browser's own transient state: `data-selecting` on the body and on the
// lines under the pointer, set and cleared inside one gesture. The server renders neither, so
// a patch landing mid-drag costs at most the tint on a line, which the next move redraws.
//
// The pointer is not captured. Capturing it retargets the click that closes the gesture to
// the capture element, which would take the plain click on a line number away from its own
// `phx-click`; the moves a capture would deliver come from the window listeners instead, the
// way the canvas takes its drags.
const Gutter = {
  mounted() {
    this.onPointerDown = (e) => this.pointerDown(e)
    this.onPointerMove = (e) => this.pointerMove(e)
    this.onPointerUp = (e) => this.pointerUp(e)
    this.onPointerCancel = () => this.clearSelection()
    this.onClickCapture = (e) => this.clickCapture(e)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    this.el.addEventListener("click", this.onClickCapture, true)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
    this.el.removeEventListener("click", this.onClickCapture, true)
  },

  pointerDown(e) {
    if (e.button !== 0) return
    // A gesture that ended outside this body never got its trailing click, and a suppression
    // left standing would eat this one.
    this.swallowClick = false
    if (e.ctrlKey || e.metaKey) return
    const ln = e.target.closest?.(".ln")
    if (!ln) return
    const anchor = this.lineOf(ln)
    if (!anchor) return
    e.stopPropagation()
    this.sel = {...anchor, pointerId: e.pointerId, shift: e.shiftKey, end: anchor.line}
    // Set before the compatibility mousedown that follows this event, whose default action
    // would start a text range that smears down the card as the pointer travels.
    this.el.setAttribute("data-selecting", "")
    this.paint()
  },

  pointerMove(e) {
    const sel = this.sel
    if (!sel || (e.pointerId !== undefined && e.pointerId !== sel.pointerId)) return
    // The button came up while the pointer was outside the window, so the pointerup that
    // would have ended this gesture was never delivered; this move is the first news of it.
    if (e.buttons === 0) return this.pointerUp(e)
    const line = this.lineAt(e.clientX, e.clientY)
    if (line === null || line === sel.end) return
    sel.end = line
    this.paint()
  },

  pointerUp(e) {
    const sel = this.sel
    if (!sel || (e.pointerId !== undefined && e.pointerId !== sel.pointerId)) return
    this.clearSelection()
    const params = {card: sel.card, side: sel.side}
    if (sel.end !== sel.line) {
      this.push({...params, line: Math.min(sel.line, sel.end), end_line: Math.max(sel.line, sel.end)})
    } else if (sel.shift) {
      this.push({...params, line: sel.line, shift: true})
    }
    // A press that neither moved nor held Shift is an ordinary click on the line number, and
    // the `phx-click` it carries opens the one-line composer on its own.
  },

  push(params) {
    // The gesture has already said what it means, so the click the release brings with it is
    // the tail of this drag rather than a new event.
    this.swallowClick = true
    this.pushEvent("comment_start", params)
  },

  clickCapture(e) {
    if (!this.swallowClick) return
    this.swallowClick = false
    e.stopPropagation()
    e.preventDefault()
  },

  // The line under a point, or null wherever a range cannot run: outside this body, over a
  // fold, or on the other side of a diff — a range lives on one side, since the two sides
  // number their lines differently.
  lineAt(x, y) {
    const at = document.elementFromPoint(x, y)
    if (!at || !this.el.contains(at)) return null
    const ln = at.closest(".line")?.querySelector(".ln")
    const found = ln && this.lineOf(ln)
    if (!found || found.side !== this.sel.side) return null
    return found.line
  },

  lineOf(ln) {
    const line = Number(ln.getAttribute("phx-value-line"))
    if (!Number.isInteger(line)) return null
    return {card: ln.getAttribute("phx-value-card"), side: ln.getAttribute("phx-value-side"), line}
  },

  // The anchor is tinted from the press onwards, so a range of one line looks like the start
  // of a range rather than like nothing happening.
  paint() {
    const {side, line, end} = this.sel
    const [first, last] = [Math.min(line, end), Math.max(line, end)]
    for (const ln of this.el.querySelectorAll(".ln")) {
      const row = ln.closest(".line")
      const found = this.lineOf(ln)
      if (!row || !found) continue
      const inside = found.side === side && found.line >= first && found.line <= last
      if (inside) row.setAttribute("data-selecting", "")
      else row.removeAttribute("data-selecting")
    }
  },

  clearSelection() {
    this.sel = null
    this.el.removeAttribute("data-selecting")
    for (const row of this.el.querySelectorAll(".line[data-selecting]")) {
      row.removeAttribute("data-selecting")
    }
  },
}

export default Gutter
