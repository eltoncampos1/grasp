# Grasp Card Groups and Semantic Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cards can be grouped under a title, rendered as a bordered section of the canvas with its own column layout, so an agent asked for "the major flows of this pull request" can put each flow in its own group; and when the canvas is zoomed out far enough that code is unreadable, every card collapses to a readable function signature.

**Architecture:** `Grasp.Session.Forest` gains `groups` (id → title) and a `group` per card; `sections/1` lays each group out independently with the existing column algorithm (edges across groups still draw, since the hook measures the DOM). The LiveView renders a `section.flow` per section with a title bar for grouped ones. MCP `set_cards` entries gain a `group` title and two tools group and ungroup cards. Semantic zoom is client-side: the Canvas hook publishes the scale as a CSS variable and a body class past a threshold; the server renders each card's signature line, hidden until then.

**Tech Stack:** Elixir/Phoenix LiveView 1.2, hook JS, CSS. No new deps.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 §Session, §Card graph, §Layout, Part 3 (updated by Task 2 and Task 3).

## Global Constraints

- Public repo: no real company, product or private project names; fixtures are `SampleApp`.
- `@doc`/`@spec`/`@moduledoc`; HEEx `attr`/`slot`; durable comments; UI state server-owned except the zoom, which is the hook's; CSS via tokens.
- Existing behaviour preserved: one card per function, coloured edges, close/close_chain/collapse, `layout/1` still returns every visible column (now section by section), the drag contract on `.node`.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test` (271 today). Never delete a test without a replacement. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Groups in the forest

**Files:** modify `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`; tests `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs`.

**Interfaces (consumed exactly by Tasks 2):**
```elixir
defstruct cards: %{}, edges: [], groups: %{}, focus: nil, next_id: 1, next_color: 0, next_group: 1
@type group :: %{id: pos_integer(), title: String.t()}
card gains group: pos_integer() | nil        # default nil
group_cards(t, title, [id]) :: {t, group_id}  # a group with that exact title is reused, else created (next_group);
                                             # each listed card moves into it (out of any other group); unknown ids
                                             # ignored; groups left empty are deleted
ungroup_cards(t, [id]) :: t                  # cards → nil; empty groups deleted
dissolve_group(t, group_id) :: t             # every member → nil; group deleted
group_of(t, id) :: group() | nil
sections(t) :: [%{group: group() | nil, columns: [[id]]}]
  # one section per group in group-id order, then a nil section for ungrouped cards when any exist;
  # a section's columns come from the existing column algorithm run over its own visible cards with
  # only the edges between them (a card whose callers are all outside the section is a source here)
layout(t) :: [[id]]                          # Enum.flat_map(sections, & &1.columns) — unchanged contract for callers
columns_of(t), depth(t, id)                  # derived from sections
move_focus(:next | :prev)                    # within the card's column in its section
close/2, close_chain/2                       # membership dropped with the card; empty groups deleted
replace([spec])                              # spec gains group: String.t() | nil (a title); same title = same group,
                                             # groups created in first-appearance order
to_map(t)                                    # card gains "group" => id | nil; adds "groups" => [%{"id","title","cards" => [ids]}]
                                             # and "sections" => [%{"group" => id | nil, "columns" => [[ids]]}]; "columns" kept
Session.group_cards/3, ungroup_cards/2, dissolve_group/2 mirror and broadcast
```

- [ ] **Step 1: Tests first.** `group_cards` creates, reuses by title, moves a card between groups, ignores unknown ids, deletes an emptied group; `ungroup_cards` and `dissolve_group`; `sections/1`: A→B ungrouped and C→D grouped "Flow" → `[%{group: %{id: 1, title: "Flow"}, columns: [[C],[D]]}, %{group: nil, columns: [[A],[B]]}]`; a grouped card whose only caller is ungrouped is a source in its section (`[[card]]`); `layout/1` equals the flattened sections; `move_focus(:next)` stays inside the section; `close` of the last member deletes the group; `replace` with `group:` titles; `to_map` shape. Keep every existing test green (default `group: nil` everywhere).
- [ ] **Step 2: Implement**, extracting the column algorithm into a private `columns(forest, ids)` so `sections/1` calls it per section.
- [ ] **Step 3: Gates, commit** `Forest: titled groups of cards laid out as sections`.

---

### Task 2: Sections on the canvas, groups over MCP

**Files:** modify `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css`, `grasp/lib/grasp/mcp/cards.ex`, `grasp/lib/grasp/mcp/tools/set_cards.ex`, `grasp/lib/grasp/mcp/server.ex`, `grasp/lib/grasp/agent/command.ex`, `README.md`, `docs/specs/2026-09-15-grasp-design.md`; create `grasp/lib/grasp/mcp/tools/group_cards.ex`, `grasp/lib/grasp/mcp/tools/ungroup_cards.ex`; tests `grasp/test/grasp_web/live/review_live_test.exs`, `grasp/test/grasp/mcp/cards_test.exs`, `grasp/test/grasp/mcp/session_tools_test.exs`, `grasp/test/grasp_web/mcp_test.exs`, `grasp/test/grasp/agent/command_test.exs` if it pins the prompt.

**Requirements:**
- Render: `<div class="flows">` holding one `<section class="flow" id={"flow-#{id || "none"}"} data-grouped={group != nil}>` per section; a grouped section has `<header class="flow__title"><h3>{title}</h3><span class="flow__count">{n} cards</span><button phx-click="dissolve_group" phx-value-group={id} title="Ungroup">ungroup</button></header>`; inside, the existing `.columns` markup. CSS: `.flows { display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-xl); padding: var(--space-m); position: relative; z-index: 1; }`, `.flow[data-grouped] { border: 1px solid var(--border); border-radius: var(--radius); padding: var(--space-s) var(--space-m) var(--space-m); background: color-mix(in srgb, var(--bg-raised) 60%, transparent); }`, `.flow__title { display: flex; align-items: baseline; gap: var(--space-s); margin: 0 0 var(--space-s); font-family: var(--sans); font-size: 13px; color: var(--fg-muted); }`, `.flow__title h3 { margin: 0; font-size: 14px; font-weight: 600; color: var(--fg); }`; the `.columns` rule loses its padding/z-index (moved to `.flows`). `open_calls` grouping and the Canvas hook are unchanged (the hook finds `#card-N` anywhere). The `dissolve_group` event calls `Session.dissolve_group/2`. Empty-canvas condition unchanged.
- MCP: `set_cards` card entry gains `field :group, :string, description: "Title of the group this card belongs to; cards sharing a title are drawn together under it"`; `Cards.prepare/2` passes `group:` (nil when absent) into the spec. New tools: `group_cards(session, title, card_ids: [integer])` → forest JSON (unknown card id → error `"unknown card: N"`, empty title → error `"title is required"`), `ungroup_cards(session, card_ids)`. Tool moduledocs describe when to group ("one group per flow when the user asks for several flows").
- System prompt, add after step 2: "When the user asks for several flows at once, give each flow its own group: put the flow's name in the `group` field of every card that belongs to it, so the canvas draws each flow in its own titled frame."
- README: groups in the reading/MCP sections; spec: §Session (`groups`), §Layout (sections), Part 3 (`group` field, two tools).
- Tests: LiveView renders a grouped section with title, count, border attribute and ungroup button; ungroup dissolves it and the cards fall back to the ungrouped section; `set_cards` with two titles → two `groups` and three sections when an ungrouped card exists; `group_cards`/`ungroup_cards` tools; `tools/list` names.
- Gates; commit `Card groups: titled sections on the canvas and over MCP`.

---

### Task 3: Semantic zoom

**Files:** modify `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`, `grasp/lib/grasp_web/components/card_components.ex`, `docs/specs/2026-09-15-grasp-design.md`, `README.md`; test `grasp/test/grasp_web/live/review_live_test.exs`, `grasp/test/grasp_web/components/card_components_test.exs` (create if absent) for the signature helper.

**Requirements:**
- Hook: `applyView()` writes `#stage{transform:…;--zoom:${scale}}` and toggles `document.body.classList` `grasp-far` when `scale < FAR_SCALE` (`const FAR_SCALE = 0.6`); the class is removed on `destroyed()`. Nothing else changes.
- Card: renders `<p class="card__signature" title={@record["id"]}>{@signature}</p>` right after the header, where `signature/1` (public in `CardComponents`, `@doc`/`@spec`, pure: record → String.t()) returns the first source line whose trimmed text starts with `def `, `defp `, `defmacro `, `defmacrop `, `defguard `, `defguardp ` or `defdelegate `, trimmed of leading whitespace and of a trailing ` do`; falls back to `Mod.fun/arity` when no such line exists. Stub and removed cards render it too (removed from their base source).
- CSS: `.card__signature { display: none; margin: 0; padding: var(--space-s) var(--space-m); font-weight: 600; white-space: nowrap; }`; under `body.grasp-far`: `.card__body, .card__also, .card__tools, .card__title, .card__stats, .badge { display: none; }`, `.card__signature { display: block; font-size: calc(14px / var(--zoom, 1)); padding: calc(var(--space-s) / var(--zoom, 1)) calc(var(--space-m) / var(--zoom, 1)); }`, `.card { min-width: 0; max-width: none; }`, `.card__header { padding-block: calc(var(--space-xs) / var(--zoom, 1)); }` (the header keeps the change badge? no — badges hidden; keep the header for its coloured tint on removed cards), `.flow__title h3 { font-size: calc(14px / var(--zoom, 1)); }`. The `--zoom` variable is set on `#stage`, so every rule must be reachable from it (all cards are inside the stage).
- Docs: spec §Layout paragraph on semantic zoom (threshold 0.6, what hides, counter-scaled signature); README one bullet.
- Tests: `signature/1` on a record with `@doc`+`@spec` lines before `def run(x) do` → `"def run(x)"`; multi-line head without ` do` on the first line → the first line trimmed; no def line → `"Mod.fun/arity"`; LiveView: `#card-1 .card__signature` present with the fixture's `greet` head.
- `mix assets.build`; gates; commit `Semantic zoom: far out, a card is its signature`.
