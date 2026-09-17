# Grasp Bottom Toolbar, Manual Signature Mode and Readable Frame Titles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The canvas toolbar moves to the bottom centre (tldraw/excalidraw style) and gains a signature-mode toggle that replaces the automatic far-zoom switch; group frame titles are larger and keep the same on-screen size at every zoom.

**Architecture:** Client-only, like the view: the hook owns the mode (`body.grasp-signatures`), marks the toggle pressed, and redraws frames when the scale changes. CSS renames `grasp-far` → `grasp-signatures`, drops the threshold, and counter-scales the frame header unconditionally.

**Tech Stack:** hook JS, CSS, one LiveView template change.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` §Layout — the toolbar sentence, the "Signature mode is the reader's choice" paragraph, the "A group's title is read at every zoom" paragraph.

## Global Constraints

- Public repo; no names beyond `SampleApp`. Comments state durable facts, never history. CSS via tokens. Anything the hook writes on a server-rendered element is re-applied in `updated()` or lives in a `phx-update="ignore"` element.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test` (411 today). Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Bottom toolbar, signature toggle, readable frame titles

**Files:** modify `grasp/assets/js/hooks/canvas.js`, `grasp/assets/js/hooks/keys.js`, `grasp/assets/css/app.css`, `grasp/lib/grasp_web/live/review_live.ex` (toolbar markup), README §Gestures; tests `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**

- **Toolbar placement.** `.toolbar` moves to `inset-block-end: var(--space-m); inset-inline-start: 50%; translate: -50% 0;` (drop `inset-block-start`/`inset-inline-end`), keeps its raised background, border, radius and shadow, gets `padding: var(--space-xs) var(--space-s)` and a slightly larger hit size (`.toolbar button { padding: var(--space-xs) var(--space-s); }`). Order of controls, left to right: `sidebar` · `−` · zoom readout · `+` · `fit` · `signatures` · `reset layout` · `ask`. A thin separator (`.toolbar__sep`, 1px `--border`) between the zoom cluster and the rest. The chat panel docks above the toolbar: `.chat { inset-block-end: calc(var(--space-m) + 3rem); }`.
- **Signature toggle.** New button `<button type="button" id="toggle-signatures" phx-update="ignore" aria-pressed="false" title="Show signatures instead of code (s)">signatures</button>`. The hook (`Canvas`) owns the mode: `this.signatures = false`; `toggleSignatures()` flips it, sets `document.body.classList.toggle("grasp-signatures", on)`, sets the button's `aria-pressed`, and calls `draw()` (card sizes change). The capture-phase click handler treats `#toggle-signatures` like the zoom buttons (client-only, `blur()`). `keys.js`: bare `s` (no modifier, not in a field, palette closed) dispatches `window.dispatchEvent(new CustomEvent("grasp:toggle-signatures"))`, which the hook listens for (like `grasp:zoom-reset`). Remove `FAR_SCALE`, the far flip in `applyView`, and the two-pass `fit()` (a single `fitOnce()` is the fit now; keep the name `fit()` for the button path). `destroyed()` removes the class.
- **CSS rename.** Every `body.grasp-far` rule becomes `body.grasp-signatures`; the comment block above them describes the manual mode. `--far-size` stays as the label size in that mode (10px); update its comment.
- **Frame titles.** New token `--frame-title-size: 18px`. Unconditionally (not only in signature mode): `.flow__title { font-size: calc(13px / var(--zoom, 1)); gap: calc(var(--space-s) / var(--zoom, 1)); margin-block-end: calc(var(--space-s) / var(--zoom, 1)); }`, `.flow__title h3 { font-size: calc(var(--frame-title-size) / var(--zoom, 1)); }`, `.flow__rename input { font-size: calc(var(--frame-title-size) / var(--zoom, 1)); }`, `.flow__count`/`.flow__title button { font-size: inherit; }`. Remove the now-redundant `body.grasp-far #stage .flow__title` rule. Because the header's stage-unit box changes with the scale, `applyView()` calls `draw()` whenever the scale differs from the scale of the last draw (store `this.drawnScale`); a pure pan does not redraw. Check `drawFrames` still measures the title after the size change (it reads rects at draw time, so it does) and that `FRAME_TITLE_GAP` is applied in stage units consistent with the counter-scaled margin: make `FRAME_TITLE_GAP` `8 / scale` at draw time so the header sits the same 8 screen pixels above the cards at every zoom.
- **README §Gestures.** Replace the "Below 50% …" bullet with the toggle (`signatures` in the toolbar or `s`), say the toolbar sits at the bottom centre, and note frame titles keep their size at any zoom.
- **Tests (LiveView).** The toolbar renders `#toggle-signatures[aria-pressed="false"]` with `phx-update="ignore"`; the toolbar's buttons appear in the specified order (assert the ids in document order via `render/1` index comparison); `#zoom-level` still present. No test for the class flip (browser work; say so in the report).
- Gates; commit `A bottom toolbar with a signature toggle; frame titles read at every zoom`.

---

### Task 2: Ctrl+drag on a frame title moves the whole group

**Files:** modify `grasp/assets/js/hooks/canvas.js`, `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css` (cursor), README §Gestures, spec §Layout (one sentence beside the card-drag paragraph); tests `forest_test.exs`, `review_live_test.exs`.

**Interfaces (produced):**

```elixir
Forest.shift_group(t, group_id, {dx, dy}) :: t   # adds {dx, dy} to the offset of every card in the group; unknown group → no-op
Session.shift_group(name, group_id, {dx, dy}) :: Forest.t()
# LiveView event "move_group" %{"group" => id, "dx" => delta, "dy" => delta}  (deltas, not absolute offsets)
```

**Requirements:**

- **Hook.** In `pointerDown`, before the card-header branch: a press with Ctrl held on a `.flow__title` (or anywhere inside it except `button, a, input`) begins a *group drag*: `this.drag = {kind: "group", ctrl: true, pointerId, flow, group: Number(flow.dataset.group), nodes: [{node, dx, dy}] for every `.node` in the flow (dx/dy from the card's `data-dx`/`data-dy`), startX, startY, moved: false}`; `preventDefault()`, `grasp-dragging` on body. `pointerMove` for `kind: "group"` sets every node's inline `translate` to `(dx + mx/s, dy + my/s)` rounded as the card drag does, then `draw()` — the frame and its title follow because `drawFrames` reads the cards' boxes. `pointerUp` pushes `move_group` with `group` and the rounded deltas `Math.round(mx / s)`, `Math.round(my / s)`; the nodes keep their inline translate until `updated()` clears them as today. `pointerCancel` clears every node's translate. A group drag never changes membership (no `groupUnder`). The Ctrl context-menu suppression applies as for a Ctrl card drag. Without Ctrl, a press on the title is still the rename click.
- **Server.** `Forest.shift_group/3` (guards: integer deltas; unknown group → unchanged), `Session.shift_group/3`, `handle_event("move_group", ...)` parsing with `int/1` and ignoring garbage; the moved cards keep their groups. `reset_layout` already clears offsets.
- **CSS.** `.flow__title { cursor: default; }`, `body.grasp-dragging .flow__title { cursor: grabbing; }`; the `h3` keeps `cursor: text`.
- **Docs.** README §Gestures: "Ctrl+drag a frame's title to move the whole group". Spec §Layout: one sentence after the per-card offset paragraph.
- **Tests.** Forest: `shift_group` adds to each member and leaves other cards; unknown group no-op. LiveView: two grouped cards, `move_group` with `dx: 40, dy: -10` → both cards' `data-dx`/`data-dy` shift by that; a card outside the group is unchanged; garbage params are a no-op.
- Gates; commit `Ctrl+drag on a frame title moves the whole group`.
