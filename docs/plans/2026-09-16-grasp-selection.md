# Grasp Selection and Untitled Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grouping by hand becomes: Shift+click cards to select them, Cmd+G to put the selection in a new (untitled) group, Cmd+Shift+G to take the selection out of its groups, drag a selected card into a frame to move the whole selection there. Groups no longer need a title; a frame without one shows a placeholder that renames in place. The per-card group menu goes away.

**Architecture:** Selection is per-tab UI state on the LiveView (a set of card ids), not session state. The forest allows `title: nil` and gains `new_group/3` (always a fresh group). The hook reports Shift+click as `toggle_select`, the Keys hook binds Cmd+G / Cmd+Shift+G / Escape, and `move_card` with a `group` applies to the dragged card plus the selection when the dragged card is selected.

**Tech Stack:** Elixir/Phoenix LiveView 1.2, hook JS, CSS.

## Global Constraints

- Public repo: no real company, product or private project names; fixtures are `SampleApp`.
- `@doc`/`@spec`/`@moduledoc`; HEEx `attr`/`slot`; durable comments; UI state server-owned (selection, rename); CSS via tokens.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test` (317 today). Tests for the removed menu are replaced by tests for the new gestures, never just deleted. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Untitled groups in the forest and over MCP

**Files:** modify `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp/mcp/tools/group_cards.ex`, `grasp/lib/grasp/mcp/tools/rename_group.ex`, spec §Session/Part 3, README; tests `forest_test.exs`, `session_test.exs`, `session_tools_test.exs`.

**Interfaces:**
```elixir
@type group :: %{id: pos_integer(), title: String.t() | nil}
Forest.new_group(t, title | nil, [id]) :: {t, group_id}   # always a fresh group; unknown ids ignored; an empty
                                                          # resulting membership still returns the id but creates nothing
Forest.group_cards(t, title, [id])                        # unchanged: reuse by exact title (title must be a binary)
Forest.rename_group(t, group_id, title | nil)             # a blank or nil title clears the title (untitled) instead of no-op
to_map/1: "title" => title | nil
MCP group_cards: `title` optional → nil creates an untitled group via new_group/3 (a present title keeps reuse-by-title)
MCP rename_group: `title` optional/blank → clears the title
```
- Tests: `new_group` twice with the same title → two groups; `rename_group` to `""` → `title: nil`; `to_map` with a nil title; tools: `group_cards` without title → a group with `"title" => nil`, `rename_group` blank clears.
- Gates; commit `Groups may be untitled`.

---

### Task 2: Select, group, ungroup, drag as a set

**Files:** modify `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/card_components.ex`, `grasp/assets/js/hooks/canvas.js`, `grasp/assets/js/hooks/keys.js`, `grasp/assets/css/app.css`, README, spec §Card/§Layout; tests `review_live_test.exs`.

**Requirements:**
- **Selection.** Assign `selected: MapSet.new()` on the LiveView. Events: `toggle_select` (`card`) adds/removes the id; `clear_selection`. A card renders `data-selected="true|false"` and class `card--selected` when selected (CSS: `outline: 2px dashed var(--accent); outline-offset: 2px`). Closing a card or reloading the index drops it from the selection. Shift+click anywhere on a card (header or body) toggles selection instead of focusing: in the Canvas hook's capture-phase click handler, when `e.shiftKey` and the target is inside a `.card` (but not inside `button, a, input, .call, .also`), `pushEvent("toggle_select", {card})`, `preventDefault()` and `stopPropagation()`; also `preventDefault()` on `pointerdown` with Shift held inside a card so the browser does not start a text range selection.
- **Keys.** In `keys.js`'s meta/ctrl branch: `g` without shift → `group_selected`; `g` with shift (`e.key === "G"` or `e.shiftKey`) → `ungroup_selected`; both `preventDefault()`. `Escape` (no modifier, not in a field, palette closed) → `clear_selection`. Events: `group_selected` → the ids are the selection, or the focused card when the selection is empty; `Session.new_group(name, nil, ids)`; then clear the selection and focus the first id. `ungroup_selected` → `Session.ungroup_cards(name, ids)` with the same fallback; selection kept.
- **Drag as a set.** `move_card` with `group`: if the dragged card is selected, `Session.add_to_group(name, group, [card | selected])`, else just the card; offsets unchanged for the others. The hook is unchanged apart from the shift handling.
- **Frames.** A group with `title: nil` renders `<h3 class="flow__title-text flow__title-text--empty">Untitled group</h3>` (placeholder, muted italic) still clickable to rename; the rename form's input starts empty; submitting blank keeps it untitled. The count and dissolve button stay. The toolbar gains nothing; the README's gestures list replaces the menu with: Shift+click to select, ⌘G group, ⇧⌘G ungroup, drag into a frame, click a title to rename, `ungroup` on the frame to dissolve.
- **Remove** the per-card group menu: the `group` toggle, `group_menu/1`, events `toggle_group_menu`/`join_group`/`new_group`/`leave_group`, `group_menu_open`, their CSS and tests. `close_overlays/1` keeps handling the callers menu and rename.
- **Tests (LiveView).** `toggle_select` on two cards → both `data-selected="true"`; `group_selected` → one untitled frame (`#flow-N .flow__title-text--empty`, "Untitled group") holding both, selection cleared; `group_selected` with an empty selection groups the focused card; `ungroup_selected` returns them to the ungrouped section; `move_card` with `group` on a selected card moves every selected card; `clear_selection`; closing a selected card drops it; renaming an untitled frame gives it a title; the old menu selectors are gone (`refute has_element?(view, ".card__group-toggle")`).
- Gates; commit `Select with Shift-click, ⌘G groups, ⇧⌘G ungroups, drag moves the set`.
