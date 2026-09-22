# Grasp Vim Keys and Nearest-Spot Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) `h` `j` `k` `l` move focus like the arrow keys, `z` folds a diff's unchanged lines (the binding `h` held), and `/` opens the palette alongside ⌘K. (2) A card opened from a call lands in the clear spot nearest the call site instead of at the bottom of a column: the placement pass tries the column right of the opener both below and above the call line, then the next column to the right, and keeps the candidate closest to where the card would ideally sit. (3) Edges are drawn above the cards, so an arrow is never hidden behind one.

**Architecture:** Task 1 is `keys.js` (three bindings), `palette.js` (the `/` chord), the help dialog rows, the guides and the spec. Task 2 is the opener branch of `placeCards()` in `canvas.js`: the existing downward sweep becomes one of four candidate sweeps (down and up, in the opener's column and the one to its right), each run against the same obstacles with the same clearance rules, and the candidate with the smallest distance from the ideal box wins. Root and caller placement are untouched. Task 3 is three z-index values and a stroke opacity in `app.css`.

**Tech Stack:** JavaScript hooks (esbuild via `mix assets.build`), HEEx, Markdown. No Elixir logic changes beyond the help dialog's static content.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 §Layout (placement of a callee), the keyboard paragraph, §Card (the `h` toggle becomes `z`), §Milestones (7.7).

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new key", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix assets.build` (no warnings), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Read each exit code; never commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce timeout — re-run once and report both runs. Commit the rebuilt `grasp/priv/static/assets/grasp.js` (and `grasp.css` only if it changed). Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Trailer exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The canvas hook has no JS harness: Task 2's verification is the bundle building, the Elixir suite staying green, and the implementer's written traces, which the reviewer checks against the code.
- No fixture source or fixture index is edited.

---

### Task 1: Vim keys

**Files:** modify `grasp/assets/js/hooks/keys.js`, `grasp/assets/js/hooks/palette.js`, `grasp/lib/grasp_web/components/help.ex`, `grasp/test/grasp_web/live/review_live_test.exs` (help content assertions), `grasp/guides/getting-started.md`, `grasp/guides/reviewing.md`, `grasp/guides/pull-requests.md`, `docs/specs/2026-09-15-grasp-design.md`; any `data-key="H"` hint on the card's `all lines`/`changes only` toggle (grep `data-key="H"` and `"h"` in `grasp/lib/grasp_web/components/card_components.ex`) becomes `Z`; rebuild the bundle.

**Bindings (the spec):**
- `h` → `move_focus parent`, `j` → `next`, `k` → `prev`, `l` → `child` — exactly what ←, ↓, ↑, → push. Implement by extending the `DIRECTIONS` map: `{ArrowLeft: "parent", ArrowRight: "child", ArrowUp: "prev", ArrowDown: "next", h: "parent", l: "child", k: "prev", j: "next"}`. Only the bare key: the existing `if (e.metaKey || e.ctrlKey) return` and `if (e.altKey) return` guards stay above it, and a Shift-modified letter arrives as uppercase so `H` does nothing (matching how `x`/`X` are told apart by `e.shiftKey` elsewhere — do not lowercase these four).
- `z` → `toggle_context_focused` (the branch `h` had). Comment: `z` is the fold key in vim, and folding the unchanged lines is what the toggle does.
- `/` → the palette: in `palette.js`'s window keydown listener, alongside the ⌘K chord, `e.key === "/"` with no `metaKey`/`ctrlKey`/`altKey`, not from an `INPUT`/`TEXTAREA`, not while `#help` is open, `preventDefault()` and `pushEvent("palette_show", {})`. Keep the help-open guard first as it is.
- The help dialog: the Keys section row for arrows reads `← → ↑ ↓` **or** `h l k j` — render both in `kbd`s on one `dt` ("←/h", "→/l", "↑/k", "↓/j" or a second `dt` line, whichever reads cleanly in the existing markup); the fold row shows `z`; the palette row shows `⌘K` or `/`.

- [ ] **Step 1: Test.** In the help-dialog test of `review_live_test.exs`, assert the dialog contains `<kbd>z</kbd>`, `<kbd>j</kbd>`, and `<kbd>/</kbd>`, and does not contain a `<kbd>h</kbd>` whose row describes folding (assert the fold row's `dd` text sits next to `z`). Run; expect failure.
- [ ] **Step 2: Implement** the bindings and the help rows as specified; grep and fix the `data-key` hint on the card toggle if one exists. Run the test; expect pass.
- [ ] **Step 3: Docs.** `getting-started.md` line ~160 and the toolbar/keys paragraph: arrows or `hjkl` walk the graph, `z` folds, `/` or ⌘K opens the palette. `reviewing.md` line ~92 and `pull-requests.md` line ~68: `h` → `z`. Spec: the keyboard paragraph in §Layout (search "Keyboard: arrows move focus" or the sentence with "`x` closes the focused card") gains `h`/`j`/`k`/`l`; §Card line ~850 `(or \`h\`)` → `(or \`z\`)`; the palette sentence gains `/`; §Milestones gets 7.7 (one line covering all three tasks: vim keys, nearest-spot placement, edges over cards — Tasks 2 and 3 do not touch the Milestones entry).
- [ ] **Step 4: Gates and commit.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Commit by path incl. `grasp/priv/static/assets/grasp.js`. Message: `hjkl walk the graph, z folds, / opens the palette` plus trailer.

---

### Task 2: A callee lands in the clear spot nearest its call

**Files:** modify `grasp/assets/js/hooks/canvas.js` (the opener branch and the sweep in `placeCards()`, one helper), `docs/specs/2026-09-15-grasp-design.md` §Layout, `grasp/guides/reviewing.md` ("A new card opens beside the card it was opened from, in the first clear space there"); rebuild the bundle.

**Rules (the spec):**
1. The **ideal box** for a callee is what the opener branch computes today: `x = opener.right + GAP_X`, `y` level with the call site (`box.top + clamp(line) - PORT_Y`). The caller branch (`calls`) and the root branch are unchanged and still use the single downward sweep.
2. For a callee, four **candidates** are swept from the ideal box against the same `obstacles` with the same `clearance(other)`:
   - (a) down, in the ideal column — the existing sweep;
   - (b) up, in the ideal column — mirror sweep: on overlap `box.bottom = other.top - clearance(other)`, `box.top = box.bottom - m.height`; strictly upwards, so the same `obstacles.length + 1` bound holds by the mirrored argument;
   - (c) down and (d) up, in the **next column**: the ideal box shifted right by `m.width + GAP_X`.
   For a grouped card the upward drop past another section's frame is `other.top - (FRAME_PAD + GAP_Y)` — which is what `clearance(other)` already yields for a frame obstacle — so no `head` term is needed upward (the card's own frame extends `FRAME_PAD` below it, not `head`). State that in the comment.
3. The **winner** is the candidate with the smallest Euclidean distance between its top-left and the ideal box's top-left; ties go to (a), then (b), (c), (d). A candidate that did not need to move is at distance 0 and wins immediately (skip the rest).
4. Everything after the choice is unchanged: rounding, `boxes.set`, `occupied.push`, `frameBoxes = framesOf(occupied)`, the `attempted` record.

- [ ] **Step 1: Implement.** Extract the sweep into a local function `sweep(startBox, direction)` returning the settled box (`direction` is `"down"` or `"up"`), used by all four candidates and by the caller/root branches (`"down"` only). Keep the comment block that explains the drop rules and add a paragraph on the four candidates and the distance rule, stating why up is allowed for a callee (the stage is unbounded both ways; a callee's edge reads fine arriving from above or below) and why the root branch stays downward-only (sections stack downwards on purpose).
- [ ] **Step 2: Traces in the report** (the reviewer checks these against the code): (i) an empty column to the right — the ideal box wins at distance 0; (ii) the ideal spot occupied by one card `C` of height `Hc` directly at the call line — (a) lands at `C.bottom + GAP_Y`, (b) at `C.top - GAP_Y - m.height`; give which wins for a call line near the top of `C` versus near its bottom; (iii) a full column of five stacked cards to the right and a free next column — (c) wins at distance `m.width + GAP_X` unless (a)/(b) find a spot closer than that; (iv) a grouped callee whose ideal spot is inside another group's frame `F` — (a) lands at `F.bottom + GAP_Y + head`, (b) at `F.top - (FRAME_PAD + GAP_Y) - m.height`, and the callee's own frame then ends `GAP_Y` clear of `F` on either side.
- [ ] **Step 3: Docs.** Spec §Layout: replace "Placement is beside the opener: a callee goes to the right of the placed card whose call site opened it (`GAP_X` 48 px), level with that call site" and the nudge sentence for callees with the four-candidate rule and the nearest-wins rule (roots and callers keep the downward drop). `reviewing.md`: "in the clear space nearest the call that opened it".
- [ ] **Step 4: Gates and commit.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Commit `canvas.js`, the bundle, the spec and the guide. Message: `A callee lands in the clear spot nearest its call` plus trailer.

---

### Task 3: Edges are drawn over the cards

**Files:** modify `grasp/assets/css/app.css` (`.connectors`, `.flows`, `.connectors .edge`), `docs/specs/2026-09-15-grasp-design.md` (the edge paragraph in §Layout — search "connectors" or "SVG"), `grasp/guides/reviewing.md` if it describes edges passing under cards; rebuild `grasp/priv/static/assets/grasp.css`.

**Rules (the spec):** the connector layer is stacked above the cards and below the frame headers: `.nodes` stays `z-index: 1`, `.connectors` becomes `z-index: 2`, `.flows` becomes `z-index: 3`. Every other stacking rule is untouched (`.frames` 0, toolbar 5, chat 4, palette 9/10). The layer keeps `pointer-events: none` and the strokes keep `pointer-events: visibleStroke`, so a card is still clicked through the layer everywhere but on a stroke. Strokes get `stroke-opacity: 0.85` so text under a crossing edge stays legible; arrowheads (`.connectors .arrow`) get the same `fill-opacity`. Check the `.card__callers ul` dropdown (`z-index: 2` inside `.nodes`' stacking context) still renders above the card it belongs to — it does, as its context is `.nodes` — and note in the report that an edge can cross an open callers menu, which is accepted.

- [ ] **Step 1: Implement** the three z-index values and the opacity; keep the comments beside them true (the `.frames` comment says "under the cards" — still true; add one sentence on `.connectors` stating the layer is above the cards so an edge is never hidden by one, and below the headers so a frame's title stays readable).
- [ ] **Step 2: Docs.** Spec §Layout edge paragraph: one sentence that edges are drawn over the cards and under the frame headers; `reviewing.md` where edges are introduced (grep "edge"): same fact in one clause.
- [ ] **Step 3: Gates and commit.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Commit `app.css`, `grasp/priv/static/assets/grasp.css`, the spec and the guide. Message: `An edge is never hidden behind a card` plus trailer.
