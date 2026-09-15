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
// server never renders a connector. The zoom readout is ignored by patches for the same
// reason: the hook writes its text on every view change.
//
// A card is dragged by its header, or from anywhere on it with Ctrl held; holding Space turns
// the whole canvas, cards included, into a pan surface.

const MIN_SCALE = 0.25
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 4
const MARGIN = 24
// Half a card header, so a connector leaves and arrives at the title rather than the corner.
const PORT_Y = 18
// A Ctrl-drag's release is still a context-menu gesture; long enough to cover the menu the
// browser opens just after the drag has ended.
const CTRL_MENU_GRACE = 300

const Canvas = {
  mounted() {
    this.stage = this.el.querySelector("#stage")
    this.svg = this.el.querySelector("#connectors")
    this.zoomLevel = this.el.querySelector("#zoom-level")
    this.view = {x: MARGIN, y: MARGIN, scale: 1}
    this.lastFocus = null
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
    this.onPointerCancel = (e) => this.pointerCancel(e)
    this.onClickCapture = (e) => this.clickCapture(e)
    this.onContextMenu = (e) => this.contextMenu(e)
    this.onKeyDown = (e) => this.spaceDown(e)
    this.onKeyUp = (e) => this.spaceUp(e)
    this.onZoomReset = () => this.resetZoom()
    this.onSpaceRelease = () => this.releaseSpace()
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    this.el.addEventListener("click", this.onClickCapture, true)
    this.el.addEventListener("contextmenu", this.onContextMenu)
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    window.addEventListener("grasp:zoom-reset", this.onZoomReset)
    // A hold that ends while the page is in the background never delivers its keyup, which
    // would leave the canvas panning on the next press.
    window.addEventListener("blur", this.onSpaceRelease)
    document.addEventListener("visibilitychange", this.onSpaceRelease)

    this.resizeObserver = new ResizeObserver(() => this.drawConnectors())
    this.resizeObserver.observe(this.stage)
    // Every session mutation pushes the focus, a move_card included, so revealing on each
    // one would pan away from the card just dropped; only a change of focus is a reveal.
    this.handleEvent("focus", ({id}) => {
      if (id === this.lastFocus) return
      this.lastFocus = id
      this.revealCard(id)
    })
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
    this.el.removeEventListener("contextmenu", this.onContextMenu)
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("grasp:zoom-reset", this.onZoomReset)
    window.removeEventListener("blur", this.onSpaceRelease)
    document.removeEventListener("visibilitychange", this.onSpaceRelease)
    document.body.classList.remove("grasp-space")
    document.body.classList.remove("grasp-dragging")
    this.resizeObserver.disconnect()
    this.style.remove()
  },

  // The translate is rounded to whole screen pixels: a fractional composited offset resamples
  // the rasterised card text and blurs it. this.view stays fractional so small deltas accumulate.
  applyView() {
    const {x, y, scale} = this.view
    this.style.textContent = `#stage{transform:translate(${Math.round(x)}px,${Math.round(y)}px) scale(${scale})}`
    if (this.zoomLevel) this.zoomLevel.textContent = `${Math.round(scale * 100)}%`
  },

  // Back to 1:1 about the centre of the canvas, so whatever you were looking at stays put.
  resetZoom() {
    this.zoomBy(1 / this.view.scale)
  },

  // Space is a page-scroll key as well as the pan modifier, and the class it sets lives on
  // <body>, which the server never renders, so a patch mid-gesture cannot drop it.
  spaceDown(e) {
    if (e.key !== " ") return
    if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return
    // Space is how a focused button or link is pressed from the keyboard; taking it there
    // would make the toolbar and the card controls unreachable without a pointer.
    if (e.target.closest?.("button, a")) return
    if (document.getElementById("palette")?.dataset.open === "true") return
    e.preventDefault()
    this.spaceHeld = true
    document.body.classList.add("grasp-space")
  },

  spaceUp(e) {
    if (e.key !== " ") return
    this.releaseSpace()
  },

  // Also the teardown for a hold the page never sees the end of, so it is unconditional: a
  // page coming back to the foreground has no key down, and a held Space re-arms on repeat.
  releaseSpace() {
    this.spaceHeld = false
    document.body.classList.remove("grasp-space")
  },

  // On macOS Ctrl+press is the context-menu gesture, so without this the menu opens over the
  // card the press is dragging, and again on the release that drops it.
  contextMenu(e) {
    if (this.drag?.ctrl || Date.now() - (this.ctrlDragEndedAt || 0) < CTRL_MENU_GRACE) {
      e.preventDefault()
    }
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
    const zoom = e.target.closest("#zoom-in, #zoom-out, #zoom-fit, #zoom-level")
    if (!zoom) return
    // The toolbar zoom buttons are client-only, so nothing should reach the server. They also
    // give focus back: left holding it, they would swallow the Space that pans the canvas.
    e.stopPropagation()
    e.preventDefault()
    zoom.blur()
    if (zoom.id === "zoom-in") this.zoomBy(1.2)
    else if (zoom.id === "zoom-out") this.zoomBy(1 / 1.2)
    else if (zoom.id === "zoom-level") this.resetZoom()
    else this.fit()
  },

  wheel(e) {
    // The toolbar floats over the canvas; a wheel there is aimed at the toolbar, and panning
    // the ground out from under it would make the buttons hard to hit.
    if (e.target.closest?.(".toolbar")) return
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
  // panning the whole canvas instead would leave that content unreachable. An element that
  // has run out of scroll in this direction absorbs nothing, so the canvas pans instead of
  // the gesture dying against the end of a list.
  scrollableUnder(e) {
    const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY)
    let el = e.target instanceof Element ? e.target : null
    while (el && el !== this.el) {
      const style = getComputedStyle(el)
      const overflow = horizontal ? style.overflowX : style.overflowY
      const scrollable = overflow === "auto" || overflow === "scroll"
      if (scrollable && this.canScroll(el, style, horizontal, e)) return true
      el = el.parentElement
    }
    return false
  },

  // A classic scrollbar on the other axis takes space out of the client box without taking
  // it out of the scroll box, so an element that only ever scrolls sideways still reports a
  // scrollHeight one scrollbar taller than its clientHeight. Measuring that gutter and
  // discounting it is what keeps a vertical wheel over a wide code body panning the canvas
  // rather than crawling through 15px of phantom overflow.
  canScroll(el, style, horizontal, e) {
    if (horizontal) {
      const gutter = Math.max(
        0,
        el.offsetWidth -
          el.clientWidth -
          parseFloat(style.borderLeftWidth) -
          parseFloat(style.borderRightWidth),
      )
      return e.deltaX > 0
        ? el.scrollLeft + el.clientWidth < el.scrollWidth - gutter
        : el.scrollLeft > 0
    }
    const gutter = Math.max(
      0,
      el.offsetHeight -
        el.clientHeight -
        parseFloat(style.borderTopWidth) -
        parseFloat(style.borderBottomWidth),
    )
    return e.deltaY > 0
      ? el.scrollTop + el.clientHeight < el.scrollHeight - gutter
      : el.scrollTop > 0
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
    if (this.spaceHeld) return this.beginPan(e)
    const ctrlCard = e.ctrlKey && e.target.closest(".card")
    if (ctrlCard) return this.beginCardDrag(e, ctrlCard, true)
    const header = e.target.closest(".card__header")
    if (header && !e.target.closest("button, a")) {
      this.beginCardDrag(e, header.closest(".card"), false)
    } else if (!e.target.closest(".card, .toolbar, button, a, input")) {
      this.beginPan(e)
    }
  },

  // Without the preventDefault the gesture also starts a native text selection, which then
  // smears across every card the pointer crosses.
  beginCardDrag(e, card, ctrl) {
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "card",
      ctrl,
      pointerId: e.pointerId,
      node: card.closest(".node"),
      id: card.id.replace("card-", ""),
      startX: e.clientX,
      startY: e.clientY,
      dx: parseInt(card.dataset.dx || "0", 10),
      dy: parseInt(card.dataset.dy || "0", 10),
      moved: false,
    }
  },

  beginPan(e) {
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "pan",
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      x: this.view.x,
      y: this.view.y,
      moved: false,
    }
  },

  // A second pointer — a touch, a pen, the other half of a pinch — reports its own stream of
  // moves and releases; only the one that started the gesture may drive or end it.
  otherPointer(e) {
    return !this.drag || (e.pointerId !== undefined && e.pointerId !== this.drag.pointerId)
  },

  pointerMove(e) {
    if (this.otherPointer(e)) return
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
      // The displacement is rounded to whole screen pixels, for the same reason applyView()
      // rounds the pan: the card then travels in whole pixels and does not shimmer. At a scale
      // other than 1 it keeps whatever subpixel phase its layout gave it — it is not on a grid.
      const s = this.view.scale
      const tx = Math.round((this.drag.dx + mx / s) * s) / s
      const ty = Math.round((this.drag.dy + my / s) * s) / s
      this.drag.node.style.translate = `${tx}px ${ty}px`
      this.drawConnectors()
    }
  },

  endDrag() {
    const drag = this.drag
    this.drag = null
    document.body.classList.remove("grasp-dragging")
    if (drag?.moved) this.suppressClick = true
    // A ctrl-press that never moved was a right-click, not a drag; blocking the menu it is
    // about to open would take the context menu away from the card entirely.
    if (drag?.ctrl && drag.moved) this.ctrlDragEndedAt = Date.now()
    return drag
  },

  // The browser took the pointer for a gesture of its own, so the drag is abandoned rather
  // than completed: nothing is pushed, the card goes back to the offset the server last
  // rendered, and no click follows a cancel for the suppression to be waiting for.
  pointerCancel(e) {
    if (this.otherPointer(e)) return
    const drag = this.endDrag()
    this.suppressClick = false
    if (drag.kind === "card") {
      drag.node.style.translate = ""
      this.drawConnectors()
    }
  },

  pointerUp(e) {
    if (this.otherPointer(e)) return
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
