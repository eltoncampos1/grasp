// The card canvas: pan, zoom, card dragging and the SVG connectors between a card and
// its children.
//
// The view is {x, y, scale} and is written to a single stylesheet rule rather than to
// #stage's style attribute, because #stage is rendered by the server and a LiveView patch
// would wipe an inline transform mid-gesture. Drag is the one exception: a dragged node
// carries an inline translate so the move is seen at once, and updated() clears it as
// soon as the server has rendered the offset it was pushed.
//
// Connector paths live inside a phx-update="ignore" <svg>, so the hook owns them and the
// server never renders a connector.

const MIN_SCALE = 0.25
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 4
const MARGIN = 24
// Half a card header, so a connector leaves and arrives at the title rather than the corner.
const PORT_Y = 18

const Canvas = {
  mounted() {
    this.stage = this.el.querySelector("#stage")
    this.svg = this.el.querySelector("#connectors")
    this.view = {x: MARGIN, y: MARGIN, scale: 1}
    this.style =
      document.getElementById("grasp-canvas-style") ||
      document.head.appendChild(
        Object.assign(document.createElement("style"), {id: "grasp-canvas-style"}),
      )
    this.applyView()

    this.onWheel = (e) => this.wheel(e)
    this.onPointerDown = (e) => this.pointerDown(e)
    this.onPointerMove = (e) => this.pointerMove(e)
    this.onPointerUp = (e) => this.pointerUp(e)
    this.onPointerCancel = () => this.endDrag()
    this.onClickCapture = (e) => this.clickCapture(e)
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    this.el.addEventListener("click", this.onClickCapture, true)

    this.resizeObserver = new ResizeObserver(() => this.drawConnectors())
    this.resizeObserver.observe(this.stage)
    this.handleEvent("focus", ({id}) => this.revealCard(id))
    this.drawConnectors()
  },

  updated() {
    // The server has rendered the offsets; drop any inline translate left by a drag.
    this.el
      .querySelectorAll(".node[style*='translate']")
      .forEach((node) => (node.style.translate = ""))
    this.drawConnectors()
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.onWheel)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
    this.el.removeEventListener("click", this.onClickCapture, true)
    this.resizeObserver.disconnect()
    this.style.remove()
  },

  applyView() {
    const {x, y, scale} = this.view
    this.style.textContent = `#stage{transform:translate(${x}px,${y}px) scale(${scale})}`
  },

  // A drag ends in a click on whatever was under the pointer, which on a card header is
  // the focus_card binding; that click is the tail of the gesture, not a new one.
  clickCapture(e) {
    if (this.suppressClick) {
      e.stopPropagation()
      e.preventDefault()
      this.suppressClick = false
      return
    }
    const zoom = e.target.closest("#zoom-in, #zoom-out, #zoom-fit")
    if (!zoom) return
    // The toolbar zoom buttons are client-only, so nothing should reach the server.
    e.stopPropagation()
    e.preventDefault()
    if (zoom.id === "zoom-in") this.zoomBy(1.2)
    else if (zoom.id === "zoom-out") this.zoomBy(1 / 1.2)
    else this.fit()
  },

  wheel(e) {
    // A zoom modifier means the canvas, whatever is under the cursor.
    if (!e.ctrlKey && !e.metaKey && this.scrollableUnder(e)) return
    e.preventDefault()
    if (e.ctrlKey || e.metaKey) {
      this.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY)
    } else {
      this.view.x -= e.deltaX
      this.view.y -= e.deltaY
      this.applyView()
    }
  },

  // Anything between the cursor and the canvas that can absorb this wheel gesture itself —
  // a code body scrolled sideways, the callers dropdown scrolled down — keeps it, because
  // panning the whole canvas instead would leave that content unreachable.
  scrollableUnder(e) {
    const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY)
    let el = e.target instanceof Element ? e.target : null
    while (el && el !== this.el) {
      const style = getComputedStyle(el)
      const overflow = horizontal ? style.overflowX : style.overflowY
      const overflows = horizontal
        ? el.scrollWidth > el.clientWidth
        : el.scrollHeight > el.clientHeight
      if ((overflow === "auto" || overflow === "scroll") && overflows) return true
      el = el.parentElement
    }
    return false
  },

  zoomBy(factor) {
    const r = this.el.getBoundingClientRect()
    this.zoomAt(factor, r.left + r.width / 2, r.top + r.height / 2)
  },

  zoomAt(factor, clientX, clientY) {
    const r = this.el.getBoundingClientRect()
    const px = clientX - r.left
    const py = clientY - r.top
    const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.view.scale * factor))
    const k = next / this.view.scale
    this.view = {x: px - (px - this.view.x) * k, y: py - (py - this.view.y) * k, scale: next}
    this.applyView()
  },

  fit() {
    const cards = Array.from(this.el.querySelectorAll(".card"))
    if (cards.length === 0) return
    const box = this.stageBox(cards)
    if (!(box.width > 0) || !(box.height > 0)) return
    const r = this.el.getBoundingClientRect()
    const scale = Math.min(
      MAX_SCALE,
      Math.max(
        MIN_SCALE,
        Math.min((r.width - 2 * MARGIN) / box.width, (r.height - 2 * MARGIN) / box.height, 1),
      ),
    )
    this.view = {x: MARGIN - box.left * scale, y: MARGIN - box.top * scale, scale}
    this.applyView()
  },

  // Bounding box of elements in unscaled stage coordinates.
  stageBox(elements) {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    let left = Infinity,
      top = Infinity,
      right = -Infinity,
      bottom = -Infinity
    for (const el of elements) {
      const b = el.getBoundingClientRect()
      left = Math.min(left, (b.left - s.left) / scale)
      top = Math.min(top, (b.top - s.top) / scale)
      right = Math.max(right, (b.right - s.left) / scale)
      bottom = Math.max(bottom, (b.bottom - s.top) / scale)
    }
    return {left, top, right, bottom, width: right - left, height: bottom - top}
  },

  revealCard(id) {
    if (id == null) return
    // A focus arriving mid-gesture would pan the ground out from under the pointer.
    if (this.drag) return
    const card = document.getElementById(`card-${id}`)
    if (!card) return
    const r = this.el.getBoundingClientRect()
    const b = card.getBoundingClientRect()
    let dx = 0,
      dy = 0
    // Pulling a wide card's right edge into view must never push its left edge out, so the
    // correction that reveals the end of a card is clamped by the one that reveals its start.
    if (b.left < r.left) dx = r.left - b.left + MARGIN
    else if (b.right > r.right) dx = Math.max(r.right - b.right - MARGIN, r.left - b.left + MARGIN)
    if (b.top < r.top) dy = r.top - b.top + MARGIN
    else if (b.bottom > r.bottom) dy = Math.max(r.bottom - b.bottom - MARGIN, r.top - b.top + MARGIN)
    if (dx || dy) {
      this.view.x += dx
      this.view.y += dy
      this.applyView()
    }
  },

  pointerDown(e) {
    if (e.button !== 0) return
    // A previous gesture that ended outside the canvas never got its trailing click, and a
    // stale suppression would eat this one.
    this.suppressClick = false
    const header = e.target.closest(".card__header")
    if (header && !e.target.closest("button, a")) {
      const card = header.closest(".card")
      const node = card.closest(".node")
      // Without this the gesture also starts a native text selection, which then smears
      // across every card the pointer crosses.
      e.preventDefault()
      this.drag = {
        kind: "card",
        node,
        id: card.id.replace("card-", ""),
        startX: e.clientX,
        startY: e.clientY,
        dx: parseInt(card.dataset.dx || "0", 10),
        dy: parseInt(card.dataset.dy || "0", 10),
        moved: false,
      }
    } else if (!e.target.closest(".card, .toolbar, button, a, input")) {
      e.preventDefault()
      this.drag = {
        kind: "pan",
        startX: e.clientX,
        startY: e.clientY,
        x: this.view.x,
        y: this.view.y,
        moved: false,
      }
    }
  },

  pointerMove(e) {
    if (!this.drag) return
    // The button came up while the pointer was outside the window, so the pointerup that
    // would have ended this gesture was never delivered; this move is the first news of it.
    if (e.buttons === 0) return this.pointerUp(e)
    const mx = e.clientX - this.drag.startX
    const my = e.clientY - this.drag.startY
    if (!this.drag.moved && Math.hypot(mx, my) < DRAG_THRESHOLD) return
    this.drag.moved = true
    if (this.drag.kind === "pan") {
      this.view.x = this.drag.x + mx
      this.view.y = this.drag.y + my
      this.applyView()
    } else {
      const {scale} = this.view
      this.drag.node.style.translate = `${this.drag.dx + mx / scale}px ${this.drag.dy + my / scale}px`
      this.drawConnectors()
    }
  },

  // A cancelled gesture (the browser took the pointer for a system drag or gesture) is
  // abandoned where it stands: no move is pushed, and the next patch restores the card.
  endDrag() {
    const drag = this.drag
    this.drag = null
    if (drag?.moved) this.suppressClick = true
    return drag
  },

  pointerUp(e) {
    if (!this.drag) return
    const drag = this.endDrag()
    if (!drag.moved) return
    if (drag.kind === "card") {
      const {scale} = this.view
      const dx = Math.round(drag.dx + (e.clientX - drag.startX) / scale)
      const dy = Math.round(drag.dy + (e.clientY - drag.startY) / scale)
      // Dropping on the offset the card already had produces no diff and so no updated()
      // to clear the fractional translate the drag left behind.
      drag.node.style.translate = `${dx}px ${dy}px`
      this.pushEvent("move_card", {card: drag.id, dx, dy})
    }
  },

  drawConnectors() {
    if (!this.svg) return
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const paths = []
    for (const child of this.el.querySelectorAll(".node__children > .node > .card")) {
      const parent = child.closest(".node__children")?.previousElementSibling
      if (!parent || !parent.classList.contains("card")) continue
      const a = parent.getBoundingClientRect()
      const b = child.getBoundingClientRect()
      const x1 = (a.right - s.left) / scale
      const y1 = (a.top - s.top) / scale + PORT_Y
      const x2 = (b.left - s.left) / scale
      const y2 = (b.top - s.top) / scale + PORT_Y
      const mid = (x1 + x2) / 2
      // The stroke is in stage units, so at the smallest zoom it would thin to under half a
      // pixel and disappear; the presentation attribute backs up the stylesheet's rule.
      paths.push(
        `<path vector-effect="non-scaling-stroke" d="M ${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2} ${y2}" />`,
      )
    }
    this.svg.setAttribute("width", String(this.stage.scrollWidth))
    this.svg.setAttribute("height", String(this.stage.scrollHeight))
    this.svg.innerHTML = paths.join("")
  },
}

export default Canvas
