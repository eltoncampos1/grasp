# Grasp Push-on-Growth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A card that grows taller — a comment thread opened or written, a diff or all-lines view toggled on, a collapse undone — pushes the cards under it down by the amount it grew, so it never comes to overlap them; when it shrinks back, the cards it pushed return, as long as nothing else has moved them since.

**Architecture:** All in the canvas hook (`grasp/assets/js/hooks/canvas.js`), which alone sees rendered heights. A `ResizeObserver` on every `.card` reports each card's height in its own CSS pixels — stage units, since the observer ignores the ancestor transform — and the hook keeps the last height per card. Growth by `dy` collects the placed cards whose stage box overlaps the grown card's box and sit level with or below it, cascades the same `dy` to whatever those would in turn run into, writes an inline translate for immediate feedback and pushes the existing `move_cards` event (`{cards, dx: 0, dy}`), which `Forest.shift_cards/3` already applies; `updated()` clears the translates as it does for drags. Each push is remembered against the card that caused it with the positions it left the pushed cards at; a later shrink of that card retracts the most recent push whose cards are still exactly where the push left them, by the same `move_cards` with `-dy`. No server change; no CSS change.

**Tech Stack:** JavaScript (`ResizeObserver`, esbuild via `mix assets.build`), Markdown.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 §Layout (the sentence "nothing moves a placed card but the reader (a drag, a group drag) or a reset" and the placement paragraph), §Known gaps (the bullet at ~line 1010 saying a card that later grows stays where it is), §Milestones (7.8); `grasp/guides/reviewing.md` lines 26–28.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new observer", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix assets.build` (no warnings), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Read exit codes; never commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce timeout — re-run once and report both runs. Commit the rebuilt `grasp/priv/static/assets/grasp.js`. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Trailer exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- No JS harness: verification is the bundle building, the Elixir suite staying green, and written traces the reviewer checks against the code. No server, CSS or fixture change in this plan; `move_cards`, `Forest.shift_cards/3` and `overlaps/3` are reused as they are.
- `placeCards()` and the drag code are not edited beyond what Task 1 names (a shared box-reading helper is allowed if `placeCards()` keeps producing the same boxes).

---

### Task 1: A card that grows pushes the cards under it down

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`mounted()`, `updated()`, `destroyed()`, new methods `observeCards()`, `cardResized(entries)`, `pushBelow(node, dy)`), `docs/specs/2026-09-15-grasp-design.md`, `grasp/guides/reviewing.md`; rebuild the bundle.

**Rules (the spec):**
1. **Heights.** `this.cardObserver = new ResizeObserver((entries) => this.cardResized(entries))`, disconnected in `destroyed()`. `observeCards()` calls `observe(card)` for every `.card` under `this.el` (observing an already-observed element is a no-op) and runs in `mounted()` and `updated()`. `this.cardHeights` is a `Map<cardId, height>` where the height is the entry's `borderBoxSize[0].blockSize` (fall back to `contentRect.height` where `borderBoxSize` is absent). The first report for a card records its height and pushes nothing.
2. **Growth.** In `cardResized`, take the entries whose card grew by more than half a pixel (`next > prev + 0.5`), whose node is placed (no `data-unplaced`) and not part of a running drag (`this.drag` null), sort them by stage top, and handle each with `pushBelow(node, next - prev)` in that order; record every entry's new height whether or not it grew.
3. **Who moves.** In `pushBelow(node, dy)`: read every placed node's stage box as `placeCards()` does (`positionOf(node)` for left/top; width and height from `getBoundingClientRect()` divided by `this.view.scale`), excluding nodes with an inline translate still pending. Let `G` be the grown card's box (its height is the new one). The pushed set `S` starts with every other box `B` with `overlaps(G, B, GAP_Y)` and `B.top >= G.top`. Cascade: for each box in `S`, shift it down by `dy`; any box `C` not in `S` and not `G` with `overlaps(shifted, C, GAP_Y)` and `C.top >= original.top` joins `S`; repeat until nothing joins (bounded by the number of boxes). Cards of other groups are pushed like any other card (their frames follow them); frames themselves are not obstacles here.
4. **The move.** If `S` is empty, do nothing. Otherwise for each node in `S`: `node.style.translate = "0px ${dy}px"` with `dy` rounded to whole stage pixels; then `this.pushEvent("move_cards", {cards: ids, dx: 0, dy})`; `this.draw()` so edges follow at once. Remember the push: `this.pushes.get(G.id)` is a stack, push `{dy, cards: Map<id, expectedTop>}` where `expectedTop` is each pushed card's top after the move (Task 2 reads it).
5. **Why uniform `dy` is right** (state it in the comment): cards under `G` were clear of it by at least `GAP_Y` before `G` grew by `dy`, so moving them by exactly `dy` restores that clearance; the cascade does the same one step further. Two cards the reader had overlapping stay overlapping by the same amount — a push restores the arrangement, it does not tidy it.
6. Shrinking pushes nothing in this task (Task 2 adds retraction). A card that is closed leaves its height entry; `observeCards()` may prune ids whose element is gone.

- [ ] **Step 1: Implement** rules 1–6. Comments state the facts (the observer ignores the stage transform so its pixels are stage units; a push restores clearance rather than tidying; the server is the owner of positions, the translate is the immediate view of the move).
- [ ] **Step 2: Traces in the report:** (i) `G` at top 0, height 300, card `B` at top 316 (GAP_Y under it), `G` grows to 400 → `B` pushed to 416, `move_cards {cards: [B], dx: 0, dy: 100}`; (ii) `B` has `C` at 316 + Hb + 16 under it → cascade pushes `C` by 100 too, one event with both ids; (iii) a card `D` to the right of `G`, x beyond `G.right + GAP_Y`, same rows → not pushed; (iv) a card `E` whose top is above `G.top` but overlapping `G` (the reader dragged it there) → not pushed; (v) `G` grows while unplaced → nothing; (vi) first observation of a freshly placed card → records only.
- [ ] **Step 3: Docs.** Spec §Layout: extend "nothing moves a placed card but the reader (a drag, a group drag) or a reset" with "or a card above it growing: a card that grows pushes the cards it would overlap down by the amount it grew, and the cards those would run into after them". Known gaps bullet (~line 1010): a card that later grows pushes the cards under it; a card dragged onto another stays where it is; a push moves cards, not frames, so a grown card can reach into another group's frame. `reviewing.md` lines 26–28 likewise.
- [ ] **Step 4: Gates and commit.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Commit `canvas.js`, the bundle, the spec and the guide. Message: `A card that grows pushes the cards under it down` plus trailer.

---

### Task 2: A card that shrinks back lets the cards it pushed return

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`cardResized`, new `retract(node, shrink)`), `docs/specs/2026-09-15-grasp-design.md`, `grasp/guides/reviewing.md`; rebuild the bundle.

**Rules (the spec):**
1. In `cardResized`, a card that shrank by more than half a pixel (`next < prev - 0.5`) and has a non-empty stack in `this.pushes` calls `retract(node, prev - next)`.
2. `retract(node, shrink)` pops pushes from the top of the stack while `push.dy <= remaining shrink` AND every card in `push.cards` still has `positionOf(node).y === expectedTop` (and exists, and is placed, and has no pending translate). For each such push: `translate = "0px -${dy}px"` on those cards, `pushEvent("move_cards", {cards, dx: 0, dy: -dy})`, `remaining -= dy`. Stop at the first push that fails either test; it and everything under it stay (the reader has moved something, so the arrangement is theirs). A partial shrink smaller than the top push's `dy` retracts nothing.
3. Whether a push is retracted is decided by the cards' positions alone, so a reader who dragged one pushed card breaks the retraction for that push and leaves the rest of the stack intact below it.

- [ ] **Step 1: Implement** rules 1–3. Comments: a retraction is a push undone, allowed only while the cards are where the push left them.
- [ ] **Step 2: Traces in the report:** (i) grow by 100 then shrink by 100 → the pushed cards return, stack empty; (ii) grow by 100, reader drags one pushed card, shrink by 100 → nothing moves, stack keeps the push; (iii) grow by 100, grow again by 50 (second push, possibly different cards), shrink by 150 → both retracted newest first; shrink by only 50 → only the second; (iv) grow by 100, shrink by 30 → nothing.
- [ ] **Step 3: Docs.** Spec §Layout sentence from Task 1 gains "…and when it shrinks back, the cards it pushed return, as long as they are still where the push left them". `reviewing.md` likewise. §Milestones: 7.8 covering both tasks.
- [ ] **Step 4: Gates and commit.** Same gates. Commit `canvas.js`, the bundle, the spec and the guide. Message: `A card that shrinks back lets the cards it pushed return` plus trailer.
