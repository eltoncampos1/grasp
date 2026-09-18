# Grasp Whiteboard Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opening a card never moves another. Every card has an absolute position on the stage; a card that has none yet is placed beside its opener by the canvas hook, which knows the rendered sizes, and reported back to the session. Reset layout and `set_cards` clear every position and let the hook lay the whole canvas out again in one pass, callers left of callees as today.

**Architecture:** The session graph swaps a card's `offset` (a delta from a flex-column slot) for `position: {x, y} | nil` in stage pixels; `Forest.sections/1` and `columns_of/1` stay as the *order* in which unplaced cards are laid out (depth within a section), not as a layout. The LiveView renders every visible card as an absolutely positioned `.node` carrying `--x/--y`, `data-depth`, `data-group` and, while unplaced, `data-unplaced` (hidden). `updated()` in the canvas hook runs a placement pass over unplaced nodes — beside the placed card that opens them, at the call site's line, nudged down past overlaps — and pushes one `place_cards` event; drags push absolute positions. Frames and edges already derive from boxes and need no change. Saved sessions move to file version 2; a version 1 file loads with its offsets dropped, so it is laid out once.

**Tech Stack:** Elixir / Phoenix LiveView, the canvas hook (vanilla JS).

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — §Session (`position`, file version 2), §Layout (whiteboard paragraph), Known gaps (milestone 6.2), Milestones.

## Global Constraints

- Public repo: names within SampleApp/acme; `@moduledoc`/`@doc`/`@spec` on everything public; HEEx `attr`; comments state durable facts, never history. UI state server-owned except the textarea draft, the canvas view/mode and the one frame between render and placement. CSS via the existing tokens.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test`. Never `git add -A`; add by path. Trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The hook has no JS test harness: Task 2's implementer verifies behaviour by reading and by a `curl`-level smoke check that the bundle builds, and lists in the report what only a browser can confirm.

---

### Task 1: Positions instead of offsets

**Files:** modify `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp/session/disk.ex` (version), `grasp/lib/grasp_web/live/review_live.ex` (events, stage markup), `grasp/lib/grasp_web/components/card_components.ex` (`card_node`), `grasp/assets/css/app.css`, `grasp/lib/grasp/mcp/cards.ex` or wherever `to_map` reaches JSON (`"position"`), tests `forest_test.exs`, `session_test.exs`, `disk_test.exs`, `review_live_test.exs`, `mcp/session_tools_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.Session.Forest
@type position :: {integer(), integer()} | nil      # stage px, top-left of the node; nil = not yet placed
# card: offset field removed, position: position() added (nil on every open/replace)
@spec move(t(), id(), {integer(), integer()}) :: t()          # sets position (absolute); unknown id no-op
@spec place(t(), [{id(), integer(), integer()}]) :: t()        # sets position only on cards whose position is nil; others untouched
@spec shift_group(t(), group_id(), {integer(), integer()}) :: t()   # adds the delta to every placed member; unplaced members stay nil
@spec reset_layout(t()) :: t()                                 # every position nil (replaces reset_offsets/1)
# to_map/1 card map: "position" => [x, y] | nil (replaces nothing — offset was never exposed)
# dump/1: "version" => 2, card "position" => [x, y] | nil.  load/2: accepts version 2; accepts version 1 by
#   reading the same fields and ignoring "offset" (positions nil); anything else :error.

# Grasp.Session: move/3 (absolute), place/2, shift_group/3, reset_layout/1 (reset_offsets/1 removed)

# ReviewLive events: "move_card" %{"card","x","y", "group"?}  (x,y absolute integers; group membership as today)
#                    "place_cards" %{"cards" => [%{"id","x","y"}]}
#                    "move_group"  %{"group","dx","dy"} unchanged; "reset_layout" → Session.reset_layout/1
# Markup: <div class="flows"> keeps one <section class="flow" data-group=…> per section for its header
#   (title, count, ungroup) — the header is positioned by the hook as today; the cards of every section render
#   in ONE flat container <div id="nodes"> as
#   <div class="node" id="node-ID" data-card=ID data-depth=D data-group=G|"" data-unplaced={position == nil}
#        style="--x: Xpx; --y: Ypx"> … card … </div>   (unplaced: --x/--y 0)
# CSS: .node { position: absolute; left: var(--x, 0px); top: var(--y, 0px); }  .node[data-unplaced] { visibility: hidden }
#      .columns/.column rules removed; .flows/.flow keep only what the header needs.
```

**Requirements:**

- Every path that used `offset` moves to `position` (`move/3`, `shift_group/3`, `card_node`, dump/load, `to_map`, the drop-into-frame `move_card` handler). `Forest.sections/1`/`columns_of/1`/`depth/2` stay and feed `data-depth` (column index within the card's section) and the sidebar count.
- `place/2` is the only server path that fills a `nil` position and never overwrites a set one, so a stale placement pushed by a tab that rendered before another tab's drag cannot undo the drag.
- `set_cards`/`replace/1` leave every position nil; `open_root/open_child/open_caller` open with nil.
- Disk: `dump/1` writes version 2; `load/2` reads 1 and 2 (`disk_test`: a version-1 document with offsets loads with positions nil; a version-2 round trip keeps positions; version 3 → `:error`). Update the Session/Disk moduledocs' file-shape sentence.
- LiveView tests: `move_card` with `x`/`y` stores the position and the node carries `--x: 40px; --y: 12px`; `place_cards` fills only nil positions (a second `place_cards` for the same card is ignored); a freshly opened card renders `data-unplaced`; after `place_cards` it does not; `reset_layout` makes every node unplaced again; `move_group` shifts placed members and leaves an unplaced one nil.
- Gates; commit `Cards keep absolute positions`.

---

### Task 2: The hook places what has no place

**Files:** modify `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css` (stage sizing if needed), README §Gestures and §MCP (arrangement wording), spec is already amended.

**Interfaces (consumed):** Task 1's markup (`.node[data-unplaced][data-depth][data-group]`, `--x/--y`), events `place_cards`, `move_card` (absolute), `move_group`, `reset_layout`.

**Requirements:**

- **Placement pass.** In `updated()` (and once in `mounted()`), before `draw()`: collect `this.el.querySelectorAll(".node[data-unplaced]")`; if none, skip. Otherwise measure every placed node's box in stage units (`getBoundingClientRect` relative to the stage, divided by scale) into an occupancy list, sort the unplaced nodes by `data-depth` then card id, and place each in turn:
  - **Opener.** The placed card holding a call site `[data-edge-to="<id>"]` (the first in document order) is the opener: the new card is its callee → `x = opener.right + GAP_X`, `y = the call site's centre line in stage units, clamped inside the opener's box, minus PORT_Y` so the edge arrives level. When instead the new card holds a call site pointing at a placed card (it is a caller opened to the left) → `x = target.left − newWidth − GAP_X`, `y = target.top`. Neither → a root: `x = the left edge of the leftmost placed box in the same `data-group` (or 0), y = the bottom of the lowest placed box in that group + GAP_Y` (0 when the group has no placed card; groups therefore stack downwards).
  - **Overlap.** While the candidate box (at `x, y`, the node's own width/height) intersects any occupied box expanded by `GAP_Y`, move `y` down to that box's bottom + GAP_Y; repeat until clear. Then record the box as occupied so later cards in the pass respect it.
  - **Constants** `GAP_X = 48` (the old column gap), `GAP_Y = 16`, PORT_Y as defined.
  - Push once: `this.pushEvent("place_cards", {cards: [{id, x, y}, …]})` with whole integers. Do not touch the nodes' inline style: the server render moves them and drops `data-unplaced`.
  - A pass runs at most once per `updated()`; a node still unplaced after the server answered (e.g. the event was rejected) is not retried in a loop — log once to the console.
- **Drag.** A card drag ends with `move_card {card, x, y[, group]}` where `x/y = the node's current --x/--y plus the rounded delta` (read the custom properties from `node.style`); the inline `translate` during the drag stays as today and is cleared on `updated()`. A group drag keeps `move_group {group, dx, dy}`.
- **Stage size.** With absolutely positioned nodes the stage has no intrinsic size: after each `draw()` set `#stage`'s `min-width/min-height` (or the svg/frames size as today) to the maximum right/bottom of all boxes + padding, so panning and `fit()` keep working; negative positions (a caller placed left of x = 0) are allowed — `fit()` already works from boxes, and the stage may be translated; if the stage cannot show negative coordinates without clipping, shift all positions by the minimum negative offset in one `place_cards`-like correction — prefer letting the pan handle it and document the choice.
- **Frames and edges** need no change; verify `drawFrames` and `drawConnectors` still read boxes only. The section header (`.flow__title`) is still translated to the frame corner.
- **Reset layout** button: unchanged event name; the hook's next `updated()` re-places everything.
- README §Gestures: "Cards stay where you put them; a new card opens beside the card it was opened from; reset layout lays everything out again." §MCP: `set_cards` lays out afresh.
- Verification without a browser: `mix assets.build` clean; a `node`-free static read-through of the placement logic against three scenarios written in the report (callee of a card mid-column; caller of a leftmost card; root in a group with two placed cards). List what only a browser can confirm (overlap nudging, negative x, fit after placement).
- Gates; commit `The canvas places new cards beside their openers`.
