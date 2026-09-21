// The card canvas: pan, zoom, card dragging and the SVG edges that run from a call site to
// the card it calls.
//
// The view is {x, y, scale} and is written to a single stylesheet rule rather than to
// #stage's style attribute, because #stage is rendered by the server and a LiveView patch
// would wipe an inline transform mid-gesture. Drag is the one exception: a dragged node
// carries an inline translate so the move is seen at once, and updated() clears it as
// soon as the server has rendered the position it was pushed.
//
// The canvas is a whiteboard: every card sits at a position of its own, in stage pixels from
// the stage's corner, and nothing moves unless a hand moves it. A card the server has no
// position for is rendered at the origin and held back from sight until this hook has measured
// it and said where it goes — the browser is the only thing that knows how large a card came
// out, so placement is the hook's alone. A pass places every such card beside the card it was
// opened from and pushes the lot in one `place_cards`; the server fills a position only where
// there is none, so a card already placed is never moved by a pass.
//
// Positions may be negative: a caller opened to the left of a card at the stage's corner lands
// left of it. Nothing shifts to make room — the stage is not clipped and the pan reaches
// wherever the cards are, so negative coordinates are shown by panning to them, and `fit()`
// measures the boxes rather than the stage.
//
// Edge paths live inside a phx-update="ignore" <svg>, so the hook owns them and the server
// never renders one. The server does render that svg's <defs>, because an arrowhead marker
// has to be in the document before a path can point at it. The zoom readout is ignored by
// patches for the same reason the edges are: the hook writes it on every view change.
//
// A group's frame is drawn by the hook too, into another ignored layer. The cards inside a
// section are dragged about freely, so the frame is measured from where they ended up rather
// than being the section's own box, and the section's header is moved to sit above it.
//
// Signature mode is a mode the reader turns on, from the toolbar or with `s`: the hook puts
// `grasp-signatures` on <body> and the rules in app.css cut every card down to its header and
// the one line that names it. The zoom decides nothing about it, so a canvas stays as it is
// read wherever it is panned or zoomed to.
//
// A frame's title is a handle too: Ctrl+drag on it moves every card of that group at once.
//
// A card is dragged by its header, or from anywhere on it with Ctrl held; holding Space turns
// the whole canvas, cards included, into a pan surface. A card dropped anywhere inside another
// group's frame joins that group — the drop is decided against the rectangles the hook drew —
// and Shift+click picks cards out into the selection ⌘G frames: the two halves of grouping by
// hand.

const MIN_SCALE = 0.25
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 4
const MARGIN = 24
// Half a card header near 1:1, so an edge arrives at the callee's title rather than at
// its corner; in signature mode the header is a thin strip and the port lands just under it.
const PORT_Y = 18
// A Ctrl-drag's release is still a context-menu gesture; long enough to cover the menu the
// browser opens just after the drag has ended.
const CTRL_MENU_GRACE = 300
// The frame's padding round the cards it holds, and the gap between it and the header above
// them. The header's bottom margin is counter-scaled, so the gap is a screen measurement that
// is divided by the scale to reach stage units: the two agree at every zoom, and a section
// nobody has dragged keeps its header exactly where the layout put it.
const FRAME_PAD = 16
const FRAME_TITLE_GAP = 8
// The gaps a placement pass leaves: GAP_X between a card and the one it was opened from,
// GAP_Y between a card and whatever it would otherwise have landed on.
const GAP_X = 48
const GAP_Y = 16
// Room round the block the cards cover, which the stage claims as its own size: a floor for
// the layers stretched across it and something for the resize observer to see. It is also the
// containing block the nodes are positioned in, which is why a node takes an intrinsic width —
// an automatic one would be cut short by the room left at the node's own position.
const STAGE_PAD = 48

// The edge layer is built as one string of markup, so anything interpolated into an attribute
// is escaped first. A function id is the server's, not a visitor's, but it is still data: a
// module named with a quoted atom can hold a quote, and one quote ends the attribute and puts
// whatever follows it into the markup as though it were mine.
const attr = (value) =>
  String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")

const Canvas = {
  mounted() {
    this.stage = this.el.querySelector("#stage")
    this.svg = this.el.querySelector("#connectors")
    this.zoomLevel = this.el.querySelector("#zoom-level")
    this.view = {x: MARGIN, y: MARGIN, scale: 1}
    this.signatures = false
    this.frames = []
    this.lastReveal = null
    this.extent = {width: 0, height: 0}
    // The cards a pass has asked the server to place, each with the box it was given and the
    // pass that asked. A card still unplaced once the answer has had time to arrive was
    // refused, and asking again would be a pass per answer for ever; until then the box stands
    // in for the position the next render will carry, so a card placed a moment later is
    // placed against it rather than on top of it.
    this.attempted = new Map()
    this.passes = 0
    this.pendingReveal = null
    // applyView() redraws whenever the scale differs from the one the frames were drawn at,
    // and the draw that ends mount covers the first frame; seeding the scale keeps that first
    // frame from being drawn twice.
    this.drawnScale = this.view.scale
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
    this.onDoubleClick = (e) => this.doubleClick(e)
    this.onContextMenu = (e) => this.contextMenu(e)
    this.onKeyDown = (e) => this.spaceDown(e)
    this.onKeyUp = (e) => this.spaceUp(e)
    this.onZoomReset = () => this.resetZoom()
    this.onToggleSignatures = () => this.toggleSignatures()
    this.onZoomFit = () => this.fit()
    this.onSpaceRelease = () => this.releaseSpace()
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    this.el.addEventListener("click", this.onClickCapture, true)
    this.el.addEventListener("dblclick", this.onDoubleClick)
    this.el.addEventListener("contextmenu", this.onContextMenu)
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    window.addEventListener("grasp:zoom-reset", this.onZoomReset)
    window.addEventListener("grasp:toggle-signatures", this.onToggleSignatures)
    window.addEventListener("grasp:zoom-fit", this.onZoomFit)
    // A hold that ends while the page is in the background never delivers its keyup, which
    // would leave the canvas panning on the next press.
    window.addEventListener("blur", this.onSpaceRelease)
    document.addEventListener("visibilitychange", this.onSpaceRelease)

    this.resizeObserver = new ResizeObserver(() => this.draw())
    this.resizeObserver.observe(this.stage)
    // Every session mutation pushes the focus, a move_card included, so revealing on each
    // one would pan away from the card just dropped; only a change of focus is a reveal.
    // A highlight arrives on the card that already has focus, so the card's highlight key
    // is part of what counts as a change — without it the first highlight pans and every
    // later one on the same card does not.
    this.handleEvent("focus", ({id}) => {
      const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || ""
      if (`${id}:${key}` === this.lastReveal) return
      // A card waiting to be placed is drawn at the stage's corner, and the focus on a card
      // just opened arrives before the render that puts it anywhere. Panning to it now would
      // pan to a corner it is about to leave, so the reveal waits for the position and
      // nothing counts as revealed until it happens.
      const node = document.getElementById(`node-${id}`)
      if (!node || node.hasAttribute("data-unplaced")) {
        this.pendingReveal = id
        return
      }
      this.lastReveal = `${id}:${key}`
      this.revealCard(id)
    })
    this.placeCards()
    this.draw()
  },

  updated() {
    // The server has rendered the positions; drop any inline translate left by a drag.
    this.el
      .querySelectorAll(".node[style*='translate']")
      .forEach((node) => (node.style.translate = ""))
    this.placeCards()
    this.draw()
    this.revealPending()
  },

  // The reveal a focus put off because its card had nowhere to be panned to. The render that
  // carries the position is the first moment there is: a card closed before it arrives is a
  // reveal to drop.
  revealPending() {
    const id = this.pendingReveal
    if (id === null) return
    const node = document.getElementById(`node-${id}`)
    if (node && node.hasAttribute("data-unplaced")) return
    this.pendingReveal = null
    if (!node) return
    const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || ""
    this.lastReveal = `${id}:${key}`
    this.revealCard(id)
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.onWheel)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
    this.el.removeEventListener("click", this.onClickCapture, true)
    this.el.removeEventListener("dblclick", this.onDoubleClick)
    this.el.removeEventListener("contextmenu", this.onContextMenu)
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("grasp:zoom-reset", this.onZoomReset)
    window.removeEventListener("grasp:toggle-signatures", this.onToggleSignatures)
    window.removeEventListener("grasp:zoom-fit", this.onZoomFit)
    window.removeEventListener("blur", this.onSpaceRelease)
    document.removeEventListener("visibilitychange", this.onSpaceRelease)
    document.body.classList.remove("grasp-space")
    document.body.classList.remove("grasp-dragging")
    document.body.classList.remove("grasp-signatures")
    this.resizeObserver.disconnect()
    this.style.remove()
  },

  // The translate is rounded to whole screen pixels: a fractional composited offset resamples
  // the rasterised card text and blurs it. this.view stays fractional so small deltas accumulate.
  applyView() {
    const {scale} = this.view
    this.writeStyle()
    // The scale is published as a custom property so a counter-scaled rule can divide by it
    // and hold a label at one size on screen. Those labels take a different box in stage units
    // at every scale, so a frame drawn round them is only right for the scale it was drawn at;
    // a pan leaves every box where it was and needs no redraw.
    if (this.drawnScale !== scale) this.draw()
    if (this.zoomLevel) this.zoomLevel.textContent = `${Math.round(scale * 100)}%`
  },

  // The one rule the hook owns on #stage: the view, the zoom the counter-scaled rules divide
  // by, and the size the stage claims. Every card is positioned absolutely, so the stage has
  // no size of its own and the layers stretched across it — the frames, the edges — would
  // have none either; the extent the last draw measured is what gives them one.
  writeStyle() {
    const {x, y, scale} = this.view
    const {width, height} = this.extent
    this.style.textContent =
      `#stage{transform:translate(${Math.round(x)}px,${Math.round(y)}px) scale(${scale});` +
      `--zoom:${scale};min-width:${width}px;min-height:${height}px}`
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
    // Shift+click a card picks it out instead of focusing it. A control or a call site keeps
    // what it already does, so Shift+clicking a call still opens the callee, and the body is
    // the comment gutter's: Shift there stretches the range being written, and a drag along
    // the line numbers reports its click against the body rather than against either number.
    // The capture phase is where the card's own phx-click has to be taken before it fires.
    const card = e.shiftKey && e.target.closest(".card")
    if (card && !e.target.closest("button, a, input, .call, .also, .card__body")) {
      e.stopPropagation()
      e.preventDefault()
      this.pushEvent("toggle_select", {card: card.id.replace("card-", "")})
      return
    }
    const control = e.target.closest(
      "#zoom-in, #zoom-out, #zoom-fit, #zoom-level, #toggle-signatures",
    )
    if (!control) return
    // The zoom buttons and the signature toggle are the hook's alone, so nothing should reach
    // the server. They also give focus back: left holding it, they would swallow the Space
    // that pans the canvas.
    e.stopPropagation()
    e.preventDefault()
    control.blur()
    if (control.id === "zoom-in") this.zoomBy(1.2)
    else if (control.id === "zoom-out") this.zoomBy(1 / 1.2)
    else if (control.id === "zoom-level") this.resetZoom()
    else if (control.id === "toggle-signatures") this.toggleSignatures()
    else this.fit()
  },

  // Signature mode. The class lives on <body>, which the server never renders, so a patch
  // cannot drop it; the button carries phx-update="ignore" for the same reason, the state it
  // shows being the hook's. Every card changes size with the mode, so every frame and every
  // edge now ends somewhere else, which only a redraw can say.
  toggleSignatures() {
    this.signatures = !this.signatures
    document.body.classList.toggle("grasp-signatures", this.signatures)
    const button = document.getElementById("toggle-signatures")
    if (button) button.setAttribute("aria-pressed", String(this.signatures))
    this.draw()
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

  // Brings every card on the canvas into view.
  fit() {
    // A frame's header holds one size on screen, so it is ~30 / scale tall in stage units and
    // the block a fit measures changes shape at the scale that fit applies: the first pass
    // re-lays-out the very boxes it measured. The second pass measures the layout the first
    // one produced and corrects it.
    this.fitPass()
    this.fitPass()
  },

  // One fit against the layout as it stands.
  fitPass() {
    // The frames are measured alongside the cards: a fit that showed only the cards would cut
    // the padding and the header off the sections holding them. A card with no position yet
    // sits at the origin and says nothing about where the canvas is.
    const boxes = Array.from(
      this.el.querySelectorAll(".node:not([data-unplaced]) .card, .frame"),
    )
    if (boxes.length === 0) return
    const box = this.stageBox(boxes)
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

  // A double click on an edge travels along it: of the two cards the edge joins, the one
  // further from the pointer is the one out of sight, so that is the card brought into view
  // and given focus. Near either end the gesture is a way to jump to the other.
  doubleClick(e) {
    const edge = e.target.closest?.(".edge")
    if (!edge) return
    const ends = [edge.dataset.from, edge.dataset.to]
      .map((id) => ({id, card: document.getElementById(`card-${id}`)}))
      .filter(({card}) => card)
    if (ends.length === 0) return
    const distance = ({card}) => {
      const b = card.getBoundingClientRect()
      return Math.hypot(b.left + b.width / 2 - e.clientX, b.top + b.height / 2 - e.clientY)
    }
    const far = ends.reduce((a, b) => (distance(b) > distance(a) ? b : a))
    e.preventDefault()
    this.pushEvent("focus_card", {card: far.id})
    this.revealCard(far.id)
  },

  revealCard(id) {
    if (id == null) return
    // A focus arriving mid-gesture would pan the ground out from under the pointer.
    if (this.drag) return
    const card = document.getElementById(`card-${id}`)
    if (!card) return
    // A card carrying a highlight is revealed at what it points at, which on a long body
    // is nowhere near the card's own top-left corner. Far out the body is not displayed and
    // the marked span has no box at all; a rect of zeros reads as the viewport's own corner
    // and would pan the canvas away from the card rather than onto it.
    const marked = card.querySelector('[data-highlight="true"]')
    const markedBox = marked && marked.getBoundingClientRect()
    const target = markedBox && (markedBox.width || markedBox.height) ? marked : card
    const r = this.el.getBoundingClientRect()
    const b = target.getBoundingClientRect()
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
    // A Shift+press on a card is the start of a selection click, not of a drag: without the
    // preventDefault the browser begins a text range that smears over every card the pointer
    // crosses on the way to the next one.
    if (e.shiftKey && e.target.closest(".card")) return e.preventDefault()
    // A frame's header is the handle the whole group is dragged by, with or without Ctrl, the
    // way a card's header is the card's: a press that moves drags every card in the group, and
    // one that does not move is the click that renames the title. The header's own controls
    // are pressed rather than dragged from.
    const title = e.target.closest(".flow__title")
    if (title && !e.target.closest("button, a, input")) {
      return this.beginGroupDrag(e, title, e.ctrlKey)
    }
    const ctrlCard = e.ctrlKey && e.target.closest(".card")
    if (ctrlCard) return this.beginCardDrag(e, ctrlCard, true)
    const header = e.target.closest(".card__header")
    // The header's own controls — the callers toggle, the file link, close — are pressed
    // rather than dragged from, and the preventDefault a drag begins with would take the
    // focus away from them.
    if (header && !e.target.closest("button, a, input")) {
      this.beginCardDrag(e, header.closest(".card"), false)
    } else if (!e.target.closest(".card, .toolbar, .chat, button, a, input")) {
      this.beginPan(e)
    }
  },

  // Without the preventDefault the gesture also starts a native text selection, which then
  // smears across every card the pointer crosses.
  beginCardDrag(e, card, ctrl) {
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    const node = card.closest(".node")
    // Where the card is now: the position the server rendered plus a displacement it has yet
    // to answer for. A second drag that started from the rendered position alone would push
    // the first one's move away again.
    const position = this.positionOf(node)
    const carried = this.translateOf(node)
    const x = Math.round(position.x + carried.x)
    const y = Math.round(position.y + carried.y)
    this.drag = {
      kind: "card",
      ctrl,
      pointerId: e.pointerId,
      node,
      id: card.id.replace("card-", ""),
      startX: e.clientX,
      startY: e.clientY,
      x,
      y,
      moved: false,
    }
  },

  // Where the server last put a node, in stage pixels from the stage's corner: the node's own
  // custom properties are the position, and the rule in app.css reads them as its left and top.
  // A node with neither is at the origin, which is where an unplaced card is rendered.
  positionOf(node) {
    return {
      x: parseInt(node.style.getPropertyValue("--x"), 10) || 0,
      y: parseInt(node.style.getPropertyValue("--y"), 10) || 0,
    }
  },

  // Every card of the group travels by the same displacement, so the cards keep their places
  // relative to one another and the frame the hook draws round them follows from their boxes.
  beginGroupDrag(e, title, ctrl) {
    const flow = title.closest(".flow")
    if (!flow) return
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "group",
      ctrl,
      pointerId: e.pointerId,
      group: Number(flow.dataset.group),
      nodes: this.nodesOfGroup(flow.dataset.group),
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
    }
  },

  // The cards of a group are anywhere on the stage, so its members are the nodes that name it
  // rather than a section's own subtree, which holds the header and nothing else.
  nodesOfGroup(group) {
    return [...this.el.querySelectorAll(".node")].filter((node) => node.dataset.group === group)
  },

  // Whether a card is still waiting for the position the hook is about to give it.
  unplaced(card) {
    return card.closest(".node")?.hasAttribute("data-unplaced") === true
  },

  // The group a node belongs to, or null for a node in none. The attribute is always there and
  // empty for a card in no group, which is not group 0.
  groupOf(node) {
    const group = node.dataset.group
    return group === "" || group === undefined ? null : Number(group)
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

  // The nodes a drag carries: a card drag its one node, a group drag every node of the group,
  // and a pan none. The translate a drag writes is the displacement alone — a node's position
  // is already its left and top — so every node of a gesture carries the same one.
  dragNodes(drag) {
    if (drag.kind === "card") return [drag.node]
    if (drag.kind === "group") return drag.nodes
    return []
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
      // The displacement is rounded to whole stage pixels, which is the unit a position is
      // stored in: the card travels through exactly the positions it can be dropped on, so
      // what the drag shows is what the release pushes. The card keeps whatever subpixel
      // phase its layout gave it — it is not on a grid.
      const s = this.view.scale
      const tx = Math.round(mx / s)
      const ty = Math.round(my / s)
      for (const node of this.dragNodes(this.drag)) {
        node.style.translate = `${tx}px ${ty}px`
      }
      this.draw()
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
  // than completed: nothing is pushed, the card goes back to the position the server last
  // rendered, and no click follows a cancel for the suppression to be waiting for.
  pointerCancel(e) {
    if (this.otherPointer(e)) return
    const drag = this.endDrag()
    this.suppressClick = false
    const nodes = this.dragNodes(drag)
    if (nodes.length) {
      nodes.forEach((node) => (node.style.translate = ""))
      this.draw()
    }
  },

  pointerUp(e) {
    if (this.otherPointer(e)) return
    const drag = this.endDrag()
    if (!drag.moved) return
    if (drag.kind === "card") {
      const {scale} = this.view
      const dx = Math.round((e.clientX - drag.startX) / scale)
      const dy = Math.round((e.clientY - drag.startY) / scale)
      // Dropping on the position the card already had produces no diff and so no updated()
      // to clear the fractional translate the drag left behind.
      drag.node.style.translate = `${dx}px ${dy}px`
      const group = this.groupUnder(e, drag)
      // The position is where the card came from plus where it was taken, in whole stage
      // pixels: the server reads integers and drops a move whose coordinates it cannot.
      const move = {card: drag.id, x: drag.x + dx, y: drag.y + dy}
      this.pushEvent("move_card", group === null ? move : {...move, group})
    } else if (drag.kind === "group") {
      const {scale} = this.view
      const dx = Math.round((e.clientX - drag.startX) / scale)
      const dy = Math.round((e.clientY - drag.startY) / scale)
      // Each node is left on the whole-pixel displacement the server is about to render as a
      // position, so a group put back where it already sat produces no diff to clear the
      // drag's fractional translate and needs none. A group drag decides no membership: the
      // cards move together and stay in the group they are the members of.
      for (const node of drag.nodes) {
        node.style.translate = `${dx}px ${dy}px`
      }
      this.pushEvent("move_group", {group: drag.group, dx, dy})
    }
  },

  // The group whose frame a drop landed in, or null when it landed anywhere else — the
  // ungrouped section, the bare canvas, or the card's own frame, none of which is a change of
  // membership. The frames are rectangles the hook drew itself, so the drop is decided by area
  // alone: a pointer anywhere inside one, padding included, joins that group, whatever element
  // happens to lie under it. A pointer inside two overlapping frames takes the later one, which
  // is the one drawn on top.
  groupUnder(e, drag) {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const x = (e.clientX - s.left) / scale
    const y = (e.clientY - s.top) / scale
    // null for a card in no group, which is equal to no group id, so such a card has no frame
    // of its own to be skipped.
    const own = this.groupOf(drag.node)
    let group = null
    for (const f of this.frames) {
      if (f.group === own) continue
      if (x >= f.left && x <= f.right && y >= f.top && y <= f.bottom) group = f.group
    }
    return group
  },

  // Frames first: they are measured from the cards, and drawing both from one read of the
  // layout keeps a dragged card's frame and its edges in step through the gesture. The scale
  // is recorded only when there is a layer to draw the frames into, so a draw that finds none
  // leaves the next applyView() to redraw.
  draw() {
    this.measureExtent()
    if (this.drawFrames()) this.drawnScale = this.view.scale
    this.drawConnectors()
  },

  // The block the placed cards cover, which the stage claims as its size and the edge layer is
  // cut to. A card with no position yet is rendered at the origin, so it is left out: it would
  // stretch the stage to a corner nothing is at. Only the far edges are measured — a card at a
  // negative coordinate lies outside the stage's own box, which clips nothing and is only ever
  // panned to.
  //
  // The node's rectangle is the card's: a node has no padding, border or margin and takes the
  // card's intrinsic width, so the extent here, the frames drawn from the cards and the boxes
  // a placement is decided against are all the same rectangles.
  measureExtent() {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    let right = 0,
      bottom = 0
    for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
      const b = node.getBoundingClientRect()
      if (!b.width && !b.height) continue
      right = Math.max(right, (b.right - s.left) / scale)
      bottom = Math.max(bottom, (b.bottom - s.top) / scale)
    }
    const width = Math.ceil(right + STAGE_PAD)
    const height = Math.ceil(bottom + STAGE_PAD)
    // Every pointermove of a drag draws; rewriting the rule each time would have the browser
    // re-parse the stylesheet for a size that has not changed.
    if (width === this.extent.width && height === this.extent.height) return
    this.extent = {width, height}
    this.writeStyle()
  },

  // One rectangle per grouped section, round the cards wherever they have been dragged to,
  // with the section's header moved to sit above its top-left corner. The rectangles are kept
  // in this.frames, which is what a drop is tested against. Answers whether it drew.
  drawFrames() {
    // The layer lives in a phx-update="ignore" subtree and so normally outlives every patch;
    // were one ever to replace it, a cached node would go on collecting frames nothing renders.
    if (!this.frameLayer?.isConnected) this.frameLayer = this.el.querySelector("#frames")
    if (!this.frameLayer) return false
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const titleGap = FRAME_TITLE_GAP / scale
    this.frames = []
    const divs = []
    // A group's cards are anywhere on the stage — a section's own subtree holds its header and
    // nothing else — so the extent of each one is gathered from the nodes that name it. A card
    // with no position yet is rendered at the origin and would drag the frame there.
    const extents = new Map()
    for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
      const group = node.dataset.group
      if (!group) continue
      const card = node.querySelector(".card")
      // A card the browser gives no box — inside a subtree that is not displayed — says
      // nothing about where the frame round it goes.
      const b = card && card.getBoundingClientRect()
      if (!b || (!b.width && !b.height)) continue
      const e = extents.get(group) || {
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity,
      }
      e.left = Math.min(e.left, (b.left - s.left) / scale)
      e.top = Math.min(e.top, (b.top - s.top) / scale)
      e.right = Math.max(e.right, (b.right - s.left) / scale)
      e.bottom = Math.max(e.bottom, (b.bottom - s.top) / scale)
      extents.set(group, e)
    }
    // Every box is read before the first header is moved. Writing `translate` invalidates the
    // layout, so a loop that measured one section and then moved its header would force a
    // reflow per section on every pointermove of a drag.
    const sections = []
    for (const flow of this.el.querySelectorAll(".flow[data-grouped]")) {
      const title = flow.querySelector(".flow__title")
      const {left, top, right, bottom} = extents.get(flow.dataset.group) || {
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity,
      }
      sections.push({
        group: Number(flow.dataset.group),
        title,
        titleBox: title && title.getBoundingClientRect(),
        // The offset the header is already carrying, which its box is measured with.
        carried: title && this.translateOf(title),
        left,
        top,
        right,
        bottom,
      })
    }

    for (const {group, title, titleBox, carried, left, top, right, bottom} of sections) {
      // A section with nothing measurable in it has no frame, and its header goes back to
      // wherever the layout puts it.
      if (left === Infinity) {
        if (title) title.style.translate = ""
        continue
      }
      let head = FRAME_PAD
      if (title) {
        const height = titleBox.height / scale
        // Where the header would sit untranslated: its own box less the offset it is carrying.
        const naturalLeft = (titleBox.left - s.left) / scale - carried.x
        const naturalTop = (titleBox.top - s.top) / scale - carried.y
        const x = left - naturalLeft
        const y = top - (height + titleGap) - naturalTop
        title.style.translate = `${x}px ${y}px`
        head = height + titleGap + FRAME_PAD
      }
      const frame = {
        group,
        left: left - FRAME_PAD,
        top: top - head,
        right: right + FRAME_PAD,
        bottom: bottom + FRAME_PAD,
      }
      this.frames.push(frame)
      divs.push(
        `<div class="frame" data-group="${attr(frame.group)}" style="left:${frame.left}px;top:${frame.top}px;` +
          `width:${frame.right - frame.left}px;height:${frame.bottom - frame.top}px"></div>`,
      )
    }
    this.frameLayer.innerHTML = divs.join("")
    return true
  },

  // The offset the hook last gave an element, in stage units. A property with one value is an
  // x with no y, as the CSS `translate` shorthand defines it, and an empty one is no offset.
  translateOf(el) {
    const [x, y] = (el.style.translate || "").split(" ").filter((v) => v !== "")
    return {x: parseFloat(x) || 0, y: parseFloat(y) || 0}
  },

  // One path per open call site: `[data-edge-to]` names the callee's card, `data-color` the
  // palette slot the call site is already painted with, so the line and the text it leaves
  // agree without the hook knowing what the colours are.
  drawConnectors() {
    // The group lives in a phx-update="ignore" subtree and so normally outlives every patch;
    // were one ever to replace it, a cached node would go on collecting paths nothing renders.
    if (!this.edges?.isConnected) this.edges = this.svg?.querySelector("#edges")
    if (!this.edges) return
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    // A card holds many call sites and a callee is often called twice, so measuring per edge
    // would read the same box over and over on every pointermove of a drag.
    const boxes = new Map()
    const boxOf = (el) => {
      let box = boxes.get(el)
      if (!box) boxes.set(el, (box = el.getBoundingClientRect()))
      return box
    }
    const within = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
    const paths = []
    for (const site of this.el.querySelectorAll("[data-edge-to]")) {
      const card = site.closest(".card")
      if (!card) continue
      const callee = document.getElementById(`card-${site.dataset.edgeTo}`)
      // A collapse takes the callee off the canvas without touching the call site's own
      // markup, so an edge is as likely to be hanging as attached.
      if (!callee) continue
      // A card waiting to be placed is drawn at the origin and not shown; an edge to or from
      // it would be a line to a corner nothing is at.
      if (this.unplaced(card) || this.unplaced(callee)) continue
      const b = boxOf(callee)
      if (!b.width && !b.height) continue

      // A call site is measured through the card that clips it: the body scrolls sideways and
      // is capped in width, so a call on a long line can be laid out well outside the card.
      // Left unclamped, its edge would start in the gutter, or far enough out to decide the
      // callee lies to the left and take the long way round to its far side.
      const c = boxOf(card)
      // A call site the browser gives no box — laid out away, or inside a subtree that is not
      // displayed — cannot say where on the card its edge starts, so the edge leaves the card
      // at the same port it arrives at rather than being dropped.
      const anchor = site.getBoundingClientRect()
      const anchored = anchor.width > 0 || anchor.height > 0

      const left = ((anchored ? within(anchor.left, c.left, c.right) : c.right) - s.left) / scale
      const right = ((anchored ? within(anchor.right, c.left, c.right) : c.right) - s.left) / scale
      const calleeLeft = (b.left - s.left) / scale
      const calleeRight = (b.right - s.left) / scale
      const callerTop = (c.top - s.top) / scale
      const callerBottom = (c.bottom - s.top) / scale
      const calleeTop = (b.top - s.top) / scale
      const calleeBottom = (b.bottom - s.top) / scale
      // An edge leaves towards the callee and arrives on the side it comes from, so a card
      // opened to the left of its caller is joined round the outside rather than through it.
      const rightward = calleeLeft > right
      const leftward = calleeRight < left
      // A callee that shares the caller's columns has no free side to arrive at: a line drawn
      // to its left or right port would cross the card and end under it, and the cards paint
      // over this layer, so the arrowhead would never show. Such a callee is joined through the
      // edge that faces the caller, above or below, at the point nearest the call site.
      const below = !rightward && !leftward && calleeTop >= callerBottom
      const above = !rightward && !leftward && calleeBottom <= callerTop
      let d
      if (below || above) {
        const siteX = anchored ? within((anchor.left + anchor.right) / 2, c.left, c.right) : c.right
        const x1 = (siteX - s.left) / scale
        const y1 = below ? callerBottom : callerTop
        // The arrival point keeps off the callee's corners by the port offset, or by half the
        // card when a signature-mode card is narrower than two of them.
        const inset = Math.min(PORT_Y, (calleeRight - calleeLeft) / 2)
        const x2 = within(x1, calleeLeft + inset, calleeRight - inset)
        const y2 = below ? calleeTop : calleeBottom
        const mid = (y1 + y2) / 2
        d = `M ${x1} ${y1} C ${x1} ${mid}, ${x2} ${mid}, ${x2} ${y2}`
      } else {
        const x1 = rightward ? right : left
        const y1 = anchored
          ? (within(anchor.top + anchor.height / 2, c.top, c.bottom) - s.top) / scale
          : callerTop + PORT_Y
        const x2 = rightward ? calleeLeft : calleeRight
        const y2 = calleeTop + PORT_Y
        const mid = (x1 + x2) / 2
        d = `M ${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2} ${y2}`
      }
      const color = /^[0-7]$/.test(site.dataset.color || "") ? site.dataset.color : null
      // The call site says what kind of hop it is; the path carries it so the stylesheet can
      // draw an HTTP request differently from a function call.
      const kind = site.dataset.kind
      // The path is drawn in stage units, which the zoom scales; `vector-effect` is what keeps
      // its stroke 2 screen pixels instead of thinning to under half a one at MIN_SCALE.
      const from = card.id.replace("card-", "")
      paths.push(
        `<path class="edge" vector-effect="non-scaling-stroke" data-from="${attr(from)}" data-to="${attr(site.dataset.edgeTo)}"` +
          (color === null ? "" : ` data-color="${color}" marker-end="url(#arrow-${color})"`) +
          (kind ? ` data-kind="${attr(kind)}"` : "") +
          ` d="${d}" />`,
      )
    }
    // The stage has no in-flow content to measure, so the layer is cut to the block the cards
    // cover. A path outside it is still drawn: the layer's overflow is visible, which is what
    // carries an edge to a card at a negative coordinate.
    this.svg.setAttribute("width", String(this.extent.width))
    this.svg.setAttribute("height", String(this.extent.height))
    this.edges.innerHTML = paths.join("")
  },

  // Every card the server has no position for, placed beside the card it was opened from and
  // pushed in one go. The pass measures, decides and pushes; it moves nothing, because the
  // render that answers carries the positions and drops `data-unplaced` with them.
  //
  // A card is placed against the boxes of the cards that already have a place, its own
  // included as soon as it has one, so a pass that lays out a whole canvas — the one after
  // `reset_layout`, where nothing is placed — reads like the one that places a single new
  // card: taken section by section in depth order, a caller is down before the callee that
  // hangs off it.
  placeCards() {
    this.passes++
    // A card the server has answered about is a card to forget; what stays behind is a card
    // whose answer is still on the wire, or one the server refused — and a pass that asked
    // again on every patch would never stop.
    for (const [id] of this.attempted) {
      const node = document.getElementById(`node-${id}`)
      if (!node || !node.hasAttribute("data-unplaced")) this.attempted.delete(id)
    }
    const waiting = [...this.el.querySelectorAll(".node[data-unplaced]")]
    if (waiting.length === 0) return
    const unplaced = waiting.filter((node) => !this.attempted.has(node.dataset.card))
    // A patch of the server's own arrives while a placement is still travelling, so the pass
    // straight after the push says nothing about whether the card was taken. A pass later than
    // that one and the answer has been and gone without the position, which is a refusal:
    // said once for the card, which stays where an unplaced card is drawn.
    for (const node of waiting) {
      const asked = this.attempted.get(node.dataset.card)
      if (!asked || asked.warned || this.passes - asked.pass < 2) continue
      asked.warned = true
      console.warn(
        `grasp: the canvas placed card ${node.dataset.card} and the session did not take it; ` +
          "the card stays hidden at the stage's corner",
      )
    }
    if (unplaced.length === 0) return

    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    // Every box is read before the first placement is decided, and each node's own rectangle
    // is kept: a call site inside a card is measured where the card is standing, and the
    // distance from the card's top is what survives the card being placed somewhere else.
    const nodes = [...this.el.querySelectorAll(".node")]
    const measured = new Map()
    for (const node of nodes) {
      const b = node.getBoundingClientRect()
      measured.set(node, {
        top: (b.top - s.top) / scale,
        width: b.width / scale,
        height: b.height / scale,
      })
    }
    // Where each card stands: the position the server rendered, or the one an earlier pass
    // asked for and is still waiting to see. A card is placed against both, so two cards
    // opened inside one round trip do not land on each other.
    //
    // A node's position is its box because `.node` has no margin and no border, and `#nodes`
    // is the one in-flow child of `#stage`, at the stage's own corner: a node's --x/--y and
    // the rectangle it is measured at are the same coordinates.
    const boxes = new Map()
    const occupied = []
    for (const node of nodes) {
      const m = measured.get(node)
      const asked = this.attempted.get(node.dataset.card)
      let box
      if (!node.hasAttribute("data-unplaced")) {
        const {x, y} = this.positionOf(node)
        box = {left: x, top: y, right: x + m.width, bottom: y + m.height, node}
      } else if (asked) {
        box = {...asked.box, node}
      } else {
        continue
      }
      boxes.set(node, box)
      occupied.push(box)
    }
    // One read of the call sites for the whole pass: a card's opener is the first card in
    // document order with a call site naming it, and a card opened as a caller is one holding
    // a call site that names a card already standing somewhere.
    const sites = []
    for (const site of this.el.querySelectorAll("[data-edge-to]")) {
      const node = site.closest(".node")
      if (node) sites.push({site, node, to: site.dataset.edgeTo})
    }

    // A depth counts from the root of the card's own section, so it says how far along a flow
    // a card is and nothing about where a card of another section stands. Taking the sections
    // one at a time is what makes the order mean something: inside one, a caller is placed
    // before the callee that hangs off it, and a group that has yet to place a card is laid
    // out against the groups already down rather than into the middle of them.
    unplaced.sort(
      (a, b) =>
        sortGroup(a) - sortGroup(b) ||
        Number(a.dataset.depth) - Number(b.dataset.depth) ||
        Number(a.dataset.card) - Number(b.dataset.card),
    )

    const placements = []
    for (const node of unplaced) {
      const m = measured.get(node)
      const id = node.dataset.card
      const opener = sites.find((hit) => hit.to === id && boxes.has(hit.node))
      const calls =
        !opener &&
        sites.find(
          (hit) => hit.node === node && boxes.has(document.getElementById(`node-${hit.to}`)),
        )
      let x, y
      if (opener) {
        // The callee stands off the opener's right edge, level with the call that opened it:
        // the edge the hook draws leaves that line and arrives at the callee's port, so the
        // two meet without a bend. A call site the browser gives no box — scrolled away, or
        // inside a fold — leaves the card at its own port height.
        const box = boxes.get(opener.node)
        const a = opener.site.getBoundingClientRect()
        const anchored = a.width > 0 || a.height > 0
        const line = anchored
          ? (a.top + a.height / 2 - s.top) / scale - measured.get(opener.node).top
          : PORT_Y
        x = box.right + GAP_X
        y = box.top + Math.min(Math.max(line, 0), box.bottom - box.top) - PORT_Y
      } else if (calls) {
        // A card opened from its callee is the caller, and a caller reads to the left of what
        // it calls, its top edge level with it.
        const box = boxes.get(document.getElementById(`node-${calls.to}`))
        x = box.left - m.width - GAP_X
        y = box.top
      } else {
        // A root belongs to nothing on the canvas, so it starts a column of its own under the
        // cards of its group; a group with nothing in it starts at the stage's corner, and the
        // overlap pass below is what stacks one such group under another.
        const group = node.dataset.group
        const peers = occupied.filter((b) => b.node.dataset.group === group)
        x = peers.length === 0 ? 0 : Math.min(...peers.map((b) => b.left))
        y = peers.length === 0 ? 0 : Math.max(...peers.map((b) => b.bottom)) + GAP_Y
      }

      // Nothing is ever laid on top of anything: a card that would land on an occupied box
      // drops below it, and below whatever that move ran it into next. Each drop is strictly
      // downwards, so one sweep per occupied box is enough to run out of them.
      let box = {left: x, top: y, right: x + m.width, bottom: y + m.height, node}
      for (let sweep = 0; sweep <= occupied.length; sweep++) {
        let moved = false
        for (const other of occupied) {
          if (!overlaps(box, other)) continue
          box.top = other.bottom + GAP_Y
          box.bottom = box.top + m.height
          moved = true
        }
        if (!moved) break
      }

      // The server reads integers and drops a placement it cannot; the box recorded is the one
      // the server will render, so the card placed next reckons with the same rectangle.
      const px = Math.round(box.left)
      const py = Math.round(box.top)
      box = {left: px, top: py, right: px + m.width, bottom: py + m.height, node}
      boxes.set(node, box)
      occupied.push(box)
      placements.push({id: Number(id), x: px, y: py})
      // The box outlives the pass: until the answer arrives the card is still `data-unplaced`
      // and drawn at the corner, and this is the only record of where it is going.
      this.attempted.set(id, {
        box: {left: px, top: py, right: box.right, bottom: box.bottom},
        pass: this.passes,
        warned: false,
      })
    }

    this.pushEvent("place_cards", {cards: placements})
  },
}

// A node's group as a number to sort by, in the order the sections are rendered in: the cards
// in no group are the last section, after every group.
function sortGroup(node) {
  return node.dataset.group === "" ? Number.MAX_SAFE_INTEGER : Number(node.dataset.group)
}

// Two boxes are clear of one another only with the placement gap between them, so a card never
// comes to rest against another card's edge.
function overlaps(a, b) {
  return (
    a.left < b.right + GAP_Y &&
    a.right > b.left - GAP_Y &&
    a.top < b.bottom + GAP_Y &&
    a.bottom > b.top - GAP_Y
  )
}

export default Canvas
