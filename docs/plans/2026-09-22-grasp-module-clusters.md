# Grasp Module Clusters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The cards of one module cluster: inside each flow (and in the groupless section) they are framed together under the module's name, the frame nested in the flow's, drawn wherever the cards are; the cards inside are the reader's to arrange. A card whose module already has a cluster in its flow lands adjacent to that cluster; other modules' frames are obstacles for it. Headers show `fun/arity` while clusters are on. A toolbar toggle (`m`) turns clusters off.

**Architecture:** Membership is derived, so the server's only change is a `data-module` attribute on the node (Task 1). Everything else is the canvas hook: a derived section level `${group}|${module}` in `drawFrames()` (module frames and hook-drawn labels inside the frames layer; flow extents become the union of module frames), a `module` drag kind reusing `move_cards`, a `grasp-modules` body class toggled like signature mode with a CSS rule hiding `.card__module` (Task 2); then placement — cluster-adjacent candidates and module frames as obstacles (Task 3); docs and the help row (Task 4).

**Tech Stack:** Phoenix LiveView (one attribute), JavaScript hook (esbuild via `mix assets.build`), CSS, Markdown.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` §Layout "#### Module clusters" (written; the authority for every rule below), §Card (header), the toolbar sentence, §Known gaps (7.9), §Milestones (7.9).

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. `@doc`/`@spec` on new public Elixir functions; HEEx components use `attr`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new frame", "today", "changed", "used to" forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching `grasp/assets/**` also `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes; never commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Trailer exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- No JS harness: hook tasks are verified by the bundle building, the Elixir suite staying green, and written traces the reviewer checks against the code.
- Existing behaviour that must hold: flow frames still follow their cards and a drop is decided by flow frames alone; `placeCards()`'s rules for roots, callers and callees (four candidates, nearest wins) hold whenever clusters are off or the module has no cluster; push-on-growth and retraction unchanged; signature mode unchanged.
- Constants: `MODULE_PAD = 12` (stage px), `MODULE_TITLE_GAP = 4`; a module frame's head = label height (screen px at scale 1 for placement, `/scale` for drawing, as flow heads are) + `MODULE_TITLE_GAP` + `MODULE_PAD`.

---

### Task 1: The node names its module

**Files:** modify `grasp/lib/grasp_web/components/card_components.ex` (the `.node` div; a private `module_of/1`), `grasp/test/grasp_web/live/review_live_test.exs`.

**Rule:** `.node` carries `data-module={module_of(@card.function_id)}` where `module_of("SampleApp.Greeter.greet/2") == "SampleApp.Greeter"` — the text before the last `.name/arity`; implemented as `Regex.run(~r/\A(.+)\.[^.\/]+\/\d+\z/, id)`, falling back to the whole id when it does not match (a card whose id has no module part still clusters, alone). Stub cards use the same attribute (the node wraps both).

- [ ] **Step 1: Test.** In `review_live_test.exs`, beside an existing test that reads a node's attributes (grep `data-group`), assert that a node opened for `SampleApp.Greeter.greet/2` carries `data-module="SampleApp.Greeter"`. Run; expect failure.
- [ ] **Step 2: Implement** the attribute and `module_of/1` (private, one comment line on the fallback). Run; expect pass. Gates; commit `card_components.ex` and the test. Message: `A node names the module its card belongs to` plus trailer.

---

### Task 2: Module frames, labels, the module drag and the toggle

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`drawFrames()`, `pointerDown`, `beginModuleDrag`, `dragNodes`, `pointerUp`, `toggleModules`, `toolbarClick`, constants, `mounted()`), `grasp/assets/css/app.css`, `grasp/lib/grasp_web/live/review_live.ex` (toolbar button `#toggle-modules`, `data-tip="Module frames"`, `data-key="M"`, `phx-update="ignore"`, `aria-pressed="true"`, placed after `#toggle-signatures`), `grasp/assets/js/hooks/keys.js` (`m` → `grasp:toggle-modules` window event, mirroring `s`), `grasp/test/grasp_web/live/review_live_test.exs` (toolbar order test gains the button); rebuild both bundles.

**Rules (the spec's "Module clusters" paragraphs 1–3 and 5):**
1. **Sections.** Clusters are keyed `${group}|${module}` (`group` is `dataset.group`, `""` for none; `module` is `dataset.module`). `drawFrames()` computes, from the placed nodes, the extent of every cluster; a module frame is `frameAround(extent, labelHeight/scale, MODULE_TITLE_GAP/scale)` with `MODULE_PAD` in place of `FRAME_PAD` (parametrise the helper: `frameAround(extent, headerHeight, titleGap, pad)`; existing callers pass `FRAME_PAD`). A flow's extent is the union of its module frames (not its cards) when clusters are on; when off, drawing is exactly as before.
2. **Drawing.** Module frames and their labels are written into the `#frames` layer as `<div class="frame frame--module" data-cluster="…">` plus `<div class="module__title" data-group="…" data-module="…">ModuleName</div>` positioned at the frame's top-left inside the pad; module frames come after flow frames in the layer so they paint on top. `.module__title` is counter-scaled (`font-size: calc(var(--module-title-size, 11px) / var(--zoom, 1))`), `pointer-events: auto`, `cursor: grab`, muted colour; `.frame--module` has a lighter border (`color-mix` of `--border` toward transparent) and no background. `this.frames` (the drop test's list) keeps flow frames only.
3. **Label height.** Measured once per draw from one rendered `.module__title` (or a hidden probe) in screen px, converted like flow heads; cache per scale.
4. **Module drag.** In `pointerDown`, before the flow-title rule: `const mtitle = e.target.closest(".module__title")` → `beginModuleDrag(e, mtitle)`: nodes = placed nodes with the same `dataset.group` and `dataset.module`, `kind: "module"`; `dragNodes` returns them; `pointerUp` pushes `move_cards {cards, dx, dy}` (no `group`). A press that does not move does nothing.
5. **Toggle.** `this.modules = true` at mount; `document.body.classList.toggle("grasp-modules", this.modules)` applied at mount and on toggle; `toggleModules()` mirrors `toggleSignatures()` (button `aria-pressed`, `this.draw()`; no re-measure needed since card sizes change only by the header text width — but the header DOES change width, so call `markRemeasure()` anyway to be safe, and say why in the comment). `toolbarClick` handles `#toggle-modules`; `keys.js` `m` dispatches `grasp:toggle-modules`; the hook listens like `grasp:toggle-signatures`.
6. **Header.** CSS: `body.grasp-modules #stage .card__module { display: none }`. Stubs render `{@card.function_id}` whole in their `h2` — split it into the same two spans (`card__module`/`card__fn`) in `card_components.ex` so stubs narrow too (one small Elixir edit, covered by the existing stub render tests if they assert the id text; adjust an assertion only if it pins the exact markup).

- [ ] **Step 1: Toolbar test.** Extend the toolbar order assertion with `toggle-modules` after `toggle-signatures`; assert `aria-pressed="true"`. Run; expect failure.
- [ ] **Step 2: Implement** rules 1–6. Comments state facts (a cluster is derived; the flow frame closes round its module frames; the label is the cluster's handle; the drop test reads flow frames alone).
- [ ] **Step 3: Traces in the report:** (i) one flow with cards of modules A and B → two module frames inside one flow frame whose extent is the union of the two module frames plus `FRAME_PAD`; (ii) clusters off → frames identical to `main`'s output for the same nodes (state why: the same code path); (iii) module label drag of A by (40, 0) → `move_cards` with A's ids only, B untouched, the flow frame grows; (iv) a card of A dragged onto B's frame → membership unchanged (flow-only drop test), A's frame stretches; (v) zoom out in clusters mode → labels keep screen size; no `move_cards` (no push logic touched).
- [ ] **Step 4: Gates and commit.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Commit `canvas.js`, `keys.js`, `app.css`, `review_live.ex`, `card_components.ex`, the test, both bundles. Message: `The cards of one module cluster under its name` plus trailer.

---

### Task 3: Placement lands a card beside its module's cluster

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`placeCards()`: obstacles and the callee/caller candidate set), rebuild the bundle.

**Rules (the spec's "Module clusters" paragraph 4):**
1. **Obstacles.** When clusters are on, `framesOf(placed)` also yields module frames (`kind: "module"`, key `${group}|${module}`, pad `MODULE_PAD`, head from the label height at scale 1). For a card of cluster `K` in flow `G`: obstacles = card boxes + flow frames of groups ≠ G (as today, clearance `FRAME_PAD + GAP_Y`) + module frames of clusters ≠ K within G (clearance `MODULE_PAD + GAP_Y`). A drop past a module frame carries `MODULE_PAD`-based head, past a flow frame the flow head, mirroring the existing `other.frame ? head : 0` with a per-obstacle head.
2. **Cluster candidates.** For a callee or caller whose cluster `K` already has placed cards in `G`: let `F` be K's module frame. Candidates, each swept as today (down and up): right of F (`x = F.right + GAP_X`, `y = ideal.y` clamped into `[F.top, F.bottom - m.height]`), below F (`x = F.left + MODULE_PAD`, `y = F.bottom + GAP_Y + moduleHead`), above F (`x = F.left + MODULE_PAD`, `y = F.top - GAP_Y - m.height - MODULE_PAD`), left of F (`x = F.left - GAP_X - m.width`, `y` clamped as for right). Winner: smallest distance from the ideal spot (beside the call, level with it); ties in that order. When K has no placed cards, the existing four candidates apply unchanged. Roots keep their rule but are also kept clear of other clusters' frames by rule 1.
3. **Clusters off** (`!this.modules`): the pass is byte-for-byte today's behaviour (guard the two additions).

- [ ] **Step 1: Implement** rules 1–3; the comment block gains a paragraph on cluster candidates and why the ideal spot still decides among them.
- [ ] **Step 2: Traces:** (i) A has cards at x 0..400, y 0..600 in flow G; a call from an A card at y 200 opens another A function → ideal (448, ~200); candidate "right of F" = (F.right + 48, 200) wins at distance ≈ MODULE_PAD + … (state the number); (ii) same but the spot right of F is taken by B's frame → the down/up sweep clears B's frame by `MODULE_PAD + GAP_Y`, compare with "below F" and pick the nearer; (iii) first card of module C opened from an A card → ordinary rule, then C's frame is an obstacle to A's next card; (iv) clusters off → identical to the 7.7 placement for the same inputs; (v) a root of flow H while flow G has clusters → below everything, clearance unchanged.
- [ ] **Step 3: Gates and commit.** `mix assets.build`, format, compile, test. Commit `canvas.js` and the bundle. Message: `A card lands beside its module's cluster` plus trailer.

---

### Task 4: Docs and the help row

**Files:** `docs/specs/2026-09-15-grasp-design.md` (§Card header sentence: "`Mod.fun/arity`, or `fun/arity` while module clusters are drawn"; the toolbar sentence gains `modules`; §Known gaps (milestone 7.9): module frames overlap once cards are dragged across, placement keeps them apart; a module with one card wears a frame like any other; clusters are per flow, so one module open in two flows is two clusters; §Milestones 7.9), `grasp/guides/reviewing.md` (a "Module clusters" subsection under groups), `grasp/guides/getting-started.md` (toolbar list gains `modules` (`m`)), `grasp/lib/grasp_web/components/help.ex` (Keys row `m` — "Module frames on or off"; Mouse row "Drag a module's name — move its cards together"), `grasp/test/grasp_web/live/review_live_test.exs` (help assertion for `<kbd>m</kbd>`).

- [ ] **Step 1:** Help rows + test; guides; spec edits (the "Module clusters" subsection is already written — verify each sentence against HEAD and correct any that drifted during Tasks 2–3, stating the fact as it is).
- [ ] **Step 2:** Gates; commit. Message: `Docs: module clusters` plus trailer.
