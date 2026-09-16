# Grasp Manual Groups and Far-Zoom Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At far zoom a card keeps its header (counter-scaled) and shows a syntax-highlighted signature; groups can be created, renamed, joined and left by hand in the viewer — from a card's group menu, by renaming a frame's title in place, and by dragging a card into another frame.

**Architecture:** `Grasp.Highlight.signature/1` renders the definition line from the cached Lumis pieces (no call wrapping). The forest gains `rename_group/3` and `add_to_group/3` (by group id). The LiveView owns a per-card group menu (like the callers menu) and an inline rename state; the Canvas hook reports the frame under the pointer on drop.

**Tech Stack:** Elixir/Phoenix LiveView 1.2, hook JS, CSS.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — §Layout (semantic zoom), §Session (groups), §Card.

## Global Constraints

- Public repo: no real company, product or private project names; fixtures are `SampleApp`.
- `@doc`/`@spec`/`@moduledoc`; HEEx `attr`/`slot`; durable comments; UI state server-owned (menus, rename state); CSS via tokens.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test` (297 today). Never delete a test without a replacement. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Far zoom keeps the header; the signature is highlighted

**Files:** modify `grasp/lib/grasp/highlight.ex`, `grasp/lib/grasp_web/components/card_components.ex`, `grasp/assets/css/app.css`, `docs/specs/2026-09-15-grasp-design.md`; tests `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp_web/components/card_components_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**
- `Grasp.Highlight.signature(record) :: Phoenix.HTML.safe()` — finds the definition line with the same rule `CardComponents.signature/1` uses today (first line whose trimmed text starts with a definition keyword; move that rule into `Highlight` as `signature_line(record) :: {line_number, text} | nil` and have `CardComponents.signature/1` delegate so the plain-text version keeps working for the `title` attribute), takes the cached pieces for that absolute line (`pieces/3`, same cache as `render/2`), drops leading whitespace from the first piece, drops a trailing `do` keyword piece and the whitespace before it, and emits `<span class="l-…">` runs exactly as `render/2` does for tokens, with no `.call` wrapping and no gutter. Fallback when there is no definition line: the escaped `record["id"]` in a plain span.
- Card: `<p class="card__signature lumis" title={…}>{@signature_html}</p>` for function, removed and stub cards (stub: plain id).
- CSS: at far zoom the header stays visible and counter-scaled: remove `.card__title`, `.badge`, `.card__stats`, `.card__tools`, `.card__close` from the hide list; add `body.grasp-far #stage .card__header { font-size: calc(var(--far-size) / var(--zoom, 1)); gap: calc(var(--space-s) / var(--zoom, 1)); padding: calc(var(--space-xs) / var(--zoom, 1)) calc(var(--space-m) / var(--zoom, 1)); }` and make `.card__title`, `.card__kind`, `.badge`, `.card__stats`, `.card__file`, `.card__tools button` inherit that size under the same scope (`font-size: inherit` or explicit calcs; badges keep their pill shape with `padding: 0 calc(var(--space-s) / var(--zoom, 1))`). The body, footer and stub prose stay hidden. Header buttons stay clickable (so close works far out).
- Spec §Layout paragraph updated; README bullet if it mentions the header.
- Tests: `Highlight.signature/1` on the fixture `greet/2` record yields spans with `l-` classes, text `def greet(name, opts \\ [])`-style without trailing ` do` and without leading spaces (check the fixture's actual head), and an `Enum.map`-style call in the head (if any fixture has one) is NOT wrapped in `.call`; fallback when no definition line. LiveView: `#card-1 .card__signature .l-keyword` (or whatever class Lumis gives `def` — read one rendered body to find it) exists.
- Gates; commit `Far zoom keeps the header and highlights the signature`.

---

### Task 2: Forest and MCP: rename and join groups

**Files:** modify `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp/mcp/server.ex`, README/spec Part 3; create `grasp/lib/grasp/mcp/tools/rename_group.ex`; tests `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs`, `grasp/test/grasp/mcp/session_tools_test.exs`, `grasp/test/grasp_web/mcp_test.exs`.

**Interfaces:**
```elixir
Forest.rename_group(t, group_id, title) :: t     # unknown group or blank title → unchanged
Forest.add_to_group(t, group_id, [id]) :: t      # moves known cards into an existing group; unknown group → unchanged; empties cleaned
Session.rename_group/3, Session.add_to_group/3   # mirror + broadcast
MCP rename_group(session, group_id, title)       # unknown group → error "unknown group: N"; blank → "title is required"
to_map/1 unchanged
```
- Tests: rename (and no-op cases), add_to_group moving a card out of another group and deleting the emptied one, tool tests, `tools/list` name.
- Gates; commit `Groups can be renamed and joined by id`.

---

### Task 3: Manual grouping in the viewer

**Files:** modify `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`, README, spec §Card/§Layout; tests `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**
- **Card group menu.** A header button `.card__group-toggle` (text `group`, `aria-expanded`) next to the callers toggle, `phx-click="toggle_group_menu" phx-value-card`. Server-owned `group_menu_open: card_id | nil` (mirroring `callers_open`). The open menu `ul.card__group-menu` lists: every existing group as `button.group-option[phx-click="join_group"][phx-value-card][phx-value-group]` (the card's current group marked `aria-current="true"`), then a form `form.group-new[phx-submit="new_group"]` with `<input name="title" placeholder="New group…">` and hidden `card`, and, when the card is grouped, `button[phx-click="leave_group"]`. Events: `join_group` → `Session.add_to_group(name, group, [card])`; `new_group` → `Session.group_cards(name, title, [card])` (blank title ignored); `leave_group` → `Session.ungroup_cards(name, [card])`; each closes the menu.
- **Rename in place.** Clicking a frame's `h3` (`phx-click="edit_group_title" phx-value-group`) swaps it for `form.flow__rename[phx-submit="rename_group"]` with `<input name="title" value={title} autofocus>` and hidden `group`; server-owned `renaming_group: id | nil`; Enter saves via `Session.rename_group/3` (blank keeps the old title), `phx-key="Escape"` / blur cancels (`cancel_rename`). Only one rename at a time.
- **Drag into a frame.** In the hook's `pointerUp` for a card drag, find the frame under the pointer: `document.elementFromPoint(e.clientX, e.clientY)?.closest(".flow[data-grouped]")` — but the dragged node is under the pointer, so temporarily set `drag.node.style.pointerEvents = "none"` during the lookup (restore after) — and read its `id` (`flow-N`). If it names a group other than the card's current one, push `move_card` with an extra `group: N`; dropping anywhere else keeps membership. LiveView `move_card` accepts the optional `group` and calls `Session.add_to_group/3` after the move. The `.flow` element renders `data-group={id}` for grouped frames.
- CSS: menu styled like `.card__callers ul`; `.group-option[aria-current="true"]` bold; `.flow__title h3` gets `cursor: text` and a hover underline; `.flow__rename input` matches the chat input.
- Docs: README "Reading the code" gains the three gestures; spec §Card and §Layout updated.
- Tests (LiveView): open the group menu, create a group from the input → frame with the title appears and the card is in it; open another card's menu and join the existing group → both in the frame; leave the group → card back in the ungrouped section and the emptied frame gone; click the title → rename form; submit → new title; `move_card` with `group` moves the card into that frame; a `move_card` without `group` keeps membership.
- Gates; commit `Groups by hand: card menu, rename in place, drag into a frame`.
