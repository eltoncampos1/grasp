# Grasp Card Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cards form a graph instead of a tree: one card per function, callers open to the left of a card without cloning anything, a card may show several callers, closing a card removes only that card, every open call site gets its own colour and the edge from that call site to the callee's card is drawn in the same colour with an arrowhead. Cards are as wide as their longest line up to a maximum.

**Architecture:** `Grasp.Session.Forest` keeps its name but becomes a graph: `cards` plus `edges` (`from` card, `to` card, the raw call `target` in the caller, a `color` index). A pure `layout/1` assigns each visible card to a column (longest path from a source, back-edges ignored) and orders rows by the callers' rows. The LiveView renders columns of cards, no recursion. `Grasp.Highlight` marks each open call site with its edge's colour and target card, the Canvas hook draws one SVG path per marked call site to the callee card with a colour-matched arrow marker, and CSS gives the eight colours. MCP tools keep their contracts; `to_map/1` gains `edges` and `columns`.

**Tech Stack:** Elixir/Phoenix LiveView 1.2, esbuild-bundled hook JS, hand-written CSS. No new dependencies.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 §Card tree and §Layout are rewritten by Task 4 of this plan; until then the user's five requests below are the binding requirement.

## Global Constraints

- Public repo: no real company, product or private project names anywhere; fixtures are `SampleApp`.
- Every public function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`/`slot`; comments state a durable why.
- UI state is server-owned; client-only state lives in hook fields or `phx-update="ignore"` elements.
- CSS uses the file's tokens; new colours are added as tokens at the top of `assets/css/app.css`.
- The user's requirements, verbatim intent: (1) opening a caller opens it to the left of the current card, never cloning the chain; several callers may show for one card; (2) a card has a maximum width and is otherwise as wide as its longest line; (3) edges are clearly visible and carry an arrowhead pointing at the callee; (4) closing a caller does not close the callee chain; (5) each open call site has a distinct colour and its edge uses the same colour.
- `mix format`, `mix compile --warnings-as-errors`, full `mix test` green (201 today), `mix assets.build` clean. Existing tests may be **rewritten** where the behaviour they pinned is being replaced by this plan (tree semantics), never silently deleted: each rewritten test keeps a test for the replacement behaviour. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Forest becomes a graph

**Files:**
- Modify: `grasp/lib/grasp/session/forest.ex` (rewrite), `grasp/lib/grasp/session.ex`
- Create: `grasp/lib/grasp/links.ex`
- Modify: `grasp/lib/grasp/mcp/cards.ex` (`opened_by/3` delegates to `Grasp.Links.call_target/3`)
- Test: `grasp/test/grasp/session/forest_test.exs` (rewrite), `grasp/test/grasp/session_test.exs`, `grasp/test/grasp/links_test.exs`

**Interfaces (produced; Tasks 2–4 consume these exactly):**

```elixir
defstruct cards: %{}, edges: [], focus: nil, next_id: 1, next_color: 0
@type card :: %{id: id(), function_id: String.t(), collapsed: boolean(), offset: {integer(), integer()}, highlight: highlight()}
@type edge :: %{from: id(), to: id(), target: String.t(), color: 0..7}
@palette_size 8

find(t, function_id) :: id() | nil                      # the one card showing this function
open_root(t, function_id) :: {t, id}                    # find-or-add, focus it
open_child(t, parent_id, function_id, opened_by \\ nil) :: {t, id | nil}
  # unknown parent → {t, nil}; find-or-add the child card; add edge %{from: parent, to: child,
  # target: opened_by || function_id, color: next} unless an edge from parent to child exists;
  # focus the child
open_caller(t, card_id, caller_function_id, target \\ nil) :: {t, id | nil}
  # unknown card → nil; find-or-add the caller card; add edge caller → card with
  # target || card.function_id (same dedupe rule); focus the caller
close(t, id) :: t          # removes the card and every edge touching it; focus → first caller, else first callee, else nil
close_chain(t, id) :: t    # removes the card and every card that is reachable from it but not from any other remaining card
toggle_collapse(t, id) :: t
hidden(t) :: MapSet.t(id)  # cards reachable only through a collapsed card's outgoing edges (see algorithm)
hidden_count(t, id) :: non_neg_integer()  # how many cards collapsing `id` hides (0 when not collapsed)
callers(t, id) :: [id]     # in edge order (creation order)
callees(t, id) :: [id]
edges(t) :: [edge]         # only edges whose both ends are visible
layout(t) :: [[id]]        # columns of visible cards, see algorithm
depth(t, id) :: non_neg_integer()  # the column index of `id` in layout/1 (0 when hidden or unknown)
move_focus(t, direction) :: t   # :parent → first caller, :child → first visible callee, :next/:prev → neighbour in the same column
focus/2, move/3, reset_offsets/1, set_highlight/3  # unchanged
replace([spec]) :: {:ok, t} | {:error, {:unknown_parent, key}}
  # same spec shape; builds with open_root/open_child so a repeated function is ONE card with
  # several edges; focus = the first entry's card
to_map(t) :: %{"focus" => id | nil,
               "cards" => [%{"id","function_id","collapsed","highlight","callers" => [id],"callees" => [id]}],
               "edges" => [%{"from","to","target","color"}],
               "columns" => [[id]]}
```

Removed: `roots`, `root?/2`, `subtree_size/2`, `parent_id`/`children`/`opened_by` on the card. `Session` mirrors: `open_caller(name, card_id, caller_id, target \\ nil)`, new `close_chain/2`; everything else keeps its name.

`Grasp.Links.call_target(index, caller_function_id, callee_function_id) :: String.t() | nil` — the raw target string of the first visible or hidden call in the caller's record that resolves (via `Grasp.Index.fetch_function/2`) to the callee's canonical id; nil when the caller does not call the callee. This is `Grasp.MCP.Cards.opened_by/3` moved into core; `Cards.opened_by/3` becomes a one-line delegate (keep its @doc/@spec; MCP tests keep passing).

**Algorithms**

`hidden/1`: `sources` = cards with no callers; if that leaves cards unreachable (a pure cycle), add the lowest-id unreached card as a source and repeat. BFS from the sources over `callees`, but never leave a collapsed card. `hidden` = all cards − visited.

`layout/1`: visible = cards − hidden. Column of a card = 1 + max column of its visible callers, computed by DFS from the sources with a stack set; an edge to a card currently on the stack is a back-edge and is ignored (so recursion does not loop and a cycle member sits one column right of the caller that reached it first). Sources are column 0. Rows: column 0 in id order; each later column sorted by `{mean row index of its callers in the previous column, id}` — a card whose callers all sit in earlier columns (skip-level edges) uses `+infinity` as the mean and so sorts after the rest, by id.

`close_chain/2`: `removed = [id | reachable_only_via(id)]` where `reachable_only_via(id)` = (cards reachable from `id`) − (cards reachable from any source other than through `id`); compute the second set by BFS from all cards that are not `id` and have no callers, plus cards whose callers are all outside the first set… simpler and correct: `keep = reach(cards − {id}, from every card ≠ id that has a caller ≠ id or has no callers)` — i.e. delete `id`, then compute `hidden`-style reachability from the remaining sources with no collapse rule; remaining unreached cards that were reachable from `id` are removed too. Write it as: remove `id` and its edges; `orphans` = cards that were in `reach(id)` before removal and are not in `reach(sources_after_removal)` after; drop them and their edges.

- [ ] **Step 1: Rewrite `forest_test.exs`** — keep every test that still holds (highlights, `move/3`, `reset_offsets/1`, `focus/2`) and replace the tree ones. Required cases:

```elixir
  test "open_root finds the existing card instead of adding a second" — open "A.f/1" twice → one card, focus it
  test "open_child links parent to child with a coloured edge and reuses the child card" —
    open_root A; open_child(A, B, "B.g/0") → edge %{from: 1, to: 2, target: "B.g/0", color: 0};
    open_child(A, C) → color 1; open_child(A, B) again → still 2 edges, focus 2
  test "colours cycle through the palette" — nine children of A → colours 0..7, 0
  test "open_caller adds a caller card to the left with an edge into the card" —
    open_root X (id 1); open_caller(1, "C.h/0", "X.f/1") → card 2, edge %{from: 2, to: 1, target: "X.f/1"}, focus 2;
    layout == [[2], [1]]; open_caller(1, "D.i/0") → layout == [[2, 3], [1]]  (two callers, one card)
  test "a function opened under two parents is one card with two edges" —
    open_root A, open_root D; open_child(A, B, "B.g/0"); open_child(D(id 2), B) → find(B) == 3, callers(3) == [1, 2]
  test "close removes one card and its edges, the chain stays" —
    A → B → C; close(B) → cards [A, C], edges [], layout == [[1, 3]] (C is now a source), focus == 1 (A was B's caller)
  test "close_chain removes what only the card reached" —
    A → B → C, and D → C; close_chain(B) → C stays (D still reaches it); A → B → C alone: close_chain(B) removes C too
  test "collapse hides what is reachable only through the card" —
    A → B → C, D → C; toggle_collapse(B) → hidden == #{} (C reachable via D); remove D's edge scenario: A → B → C only → hidden == #{C}, hidden_count(B) == 1, layout == [[A], [B]]
  test "layout ignores back-edges" — A → B → A → layout == [[A], [B]]
  test "rows follow the callers" — A(1), D(2) sources; A → C(3), D → B(4) → column 1 order is [3, 4]? No: mean caller row of 3 is 0 (A), of 4 is 1 (D) → [3, 4]; swap the edges (A → B, D → C) → [4, 3]
  test "move_focus walks callers, callees and the column" — A → B, A → C: focus B; :parent → A; :child → B; :next → C; :prev → B
  test "replace builds one card per function" — spec [a: A, b: B parent a, c: B parent nil] → 2 cards, edge a→b once, focus 1
  test "replace with an unknown parent is an error" (unchanged)
  test "to_map has the JSON shape" — cards with callers/callees, edges with colour, columns, focus
```

Write real assertions, not the sketches above; pick unambiguous function ids (`"A.f/1"`, `"B.g/0"`, …).

- [ ] **Step 2: `links_test.exs`** — with the fixture index: `call_target(index, show/2, greet/2) == "SampleApp.Greeter.greet/1"` (the alias the controller uses), `call_target(index, hello_render/1, greet/2) == "SampleApp.Greeter.greet/1"` (hidden call), `call_target(index, wrap/1, show/2) == nil`.

- [ ] **Step 3: `session_test.exs`** — adjust to the new signatures (`open_caller/4`, `close_chain/2`, `set_cards` still `{:ok, forest}`); broadcasts unchanged.

- [ ] **Step 4: Implement**, run `mix test test/grasp`, then the whole suite — expect failures ONLY in the LiveView/component/MCP tests that Tasks 2–4 own (`review_live_test`, `palette_test`, `chat_test` unaffected, `session_tools_test`, `mcp_test`, `cards_test` should still pass since `prepare/2` output is unchanged). List the failing files in your report; do not fix them here. Commit: `Forest: a graph of cards with coloured edges`.

The suite being red at the end of this task is expected and ruled acceptable; Task 2 turns it green.

---

### Task 2: Columns, fit-content cards, coloured call sites

**Files:**
- Modify: `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp/highlight.ex`, `grasp/assets/css/app.css`, `grasp/assets/js/hooks/keys.js`
- Test: `grasp/test/grasp_web/live/review_live_test.exs`, `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp_web/live/palette_test.exs` (adjust)

**Interfaces:**
- `Grasp.Highlight.render/2` replaces `open_targets: [String.t()]` with `open_calls: %{String.t() => %{to: id, color: 0..7}}` keyed by the raw call target. A `.call` whose `target` is a key renders `data-open="true" data-color={color} data-edge-to={to}`; others render `data-open="false"` and no colour attributes.
- Card component (`card/1`) renders one card, no recursion; `card_node/1` becomes a thin wrapper `<div class="node" style="--dx…">` around one card (keeps the drag contract: the hook translates `.node`). `data-depth` = column index. The header's collapse button shows `▸ N` from `Forest.hidden_count/2` when collapsed and `▾` otherwise, and only renders when the card has callees. The close button title reads `Close (x) · Shift+x closes the chain`. The "Also calls" footer buttons render `data-open`/`data-color`/`data-edge-to` the same way when an edge with that target exists.
- `open_calls` for a card = for each edge with `from == card.id`: `{edge.target => %{to: edge.to, color: edge.color}}`.
- `ReviewLive.render/1`: `<div class="columns">` with `<div class="column" :for={column <- Forest.layout(@forest)}>` each holding a `card_node` per id. Empty state when `@forest.cards == %{}`. Events: `open_caller` computes `target = Grasp.Links.call_target(index, caller_canonical, card.function_id)` and calls `Session.open_caller(name, card_id, caller, target)`; new `close_chain` (`phx-value-card`) and `close_focused_chain` (keyboard); `move_focus` unchanged names.
- `keys.js`: `x` → `close_focused`, `X` (shift) → `close_focused_chain`; everything else unchanged.
- CSS: `.card { width: max-content; min-width: 24rem; max-width: var(--card-max-width); }` with `--card-max-width: 60rem` replacing `--card-width`; `.columns { display: flex; align-items: flex-start; gap: var(--space-xl); padding: var(--space-m); position: relative; z-index: 1; }`, `.column { display: flex; flex-direction: column; gap: var(--space-m); align-items: flex-start; }`, `.node { translate: var(--dx, 0px) var(--dy, 0px); }`; remove `.roots`, `.node__children`. Eight edge tokens on `:root`: `--edge-0: #0969da; --edge-1: #1a7f37; --edge-2: #8250df; --edge-3: #bc4c00; --edge-4: #bf3989; --edge-5: #1b7c83; --edge-6: #cf222e; --edge-7: #9a6700;` and `[data-color="0"] { --edge-color: var(--edge-0); }` … through 7. Call site: `.call[data-open="true"] { outline: 2px solid var(--edge-color); outline-offset: 1px; border-radius: 2px; border-bottom-style: solid; background: color-mix(in srgb, var(--edge-color) 12%, transparent); }`; the `.also[data-open="true"]` button gets the same outline. The existing `.call[data-highlight="true"]` ring stays as is (it is the agent's pointer, accent-coloured, and sits inside the outline when both apply — that is acceptable).

- [ ] **Step 1: Tests first.** `highlight_test.exs`: an open call renders `data-color="3"` and `data-edge-to="7"` when `open_calls: %{CALL_TARGET => %{to: 7, color: 3}}`; a call not in the map has no `data-color`. `review_live_test.exs`: rewrite the tree tests — (a) clicking a call opens the callee in column 1 (`.column:nth-child(2) #card-2`) and marks the call `[data-open="true"][data-color="0"][data-edge-to="2"]`; (b) opening a caller from the menu puts the caller in column 0 and the card in column 1 with no second copy of the card (`#card-1` appears once, `.card[data-function-id=...]` count 1); opening a second caller stacks it in column 0 (two `.card`s in `.column:first-child`); (c) closing the middle card of a three-card chain leaves the other two, and the last one becomes column 0; (d) Shift+x / `close_chain` removes the chain; (e) collapse shows `▸ 1` and hides the callee; (f) the same function opened from two parents renders once with two coloured call sites (different `data-color`). Keep the highlight tests. `palette_test.exs`: Shift+Enter still opens a child of the focused card (edge exists), adjust selectors.

- [ ] **Step 2: Implement**, `mix format`, `mix compile --warnings-as-errors`, `mix assets.build`, full `mix test` green except the MCP files Task 4 owns (`session_tools_test`, `mcp_test`) if `to_map` assertions fail — report which. Commit: `Cards render in columns, call sites carry their edge colour`.

---

### Task 3: Coloured edges with arrowheads

**Files:**
- Modify: `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`, `grasp/lib/grasp_web/live/review_live.ex` (SVG defs)

**Interfaces:**
- The `#connectors` SVG (still `phx-update="ignore"`) is rendered by the server with `<defs>` holding eight `<marker id="arrow-N" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" class="arrow arrow--N"/></marker>` and an empty `<g id="edges"></g>`; the hook writes only into `#edges`.
- `drawConnectors()` iterates `this.el.querySelectorAll("[data-edge-to]")`: `from` = the element's rect, `to` = `#card-{id}`'s rect. Start point: the element's right-middle when the callee card's left edge is to the right of the element's right edge, else the element's left-middle. End point: the callee card's left edge at `PORT_Y` when approaching from the left, else its right edge at `PORT_Y`. Path: cubic with horizontal control points at the midpoint x (as today), `class="edge edge--N" marker-end="url(#arrow-N)"` with N from `data-color`. Skip when either rect is missing (collapsed/hidden target). Stage coordinates and `vector-effect="non-scaling-stroke"` as today. The marker itself scales with the stroke; that is fine.
- CSS: `.connectors .edge { fill: none; stroke: var(--edge-color, var(--border)); stroke-width: 2; }`, `.edge--N { --edge-color: var(--edge-N); }` ×8 (reuse the `[data-color]` idea: give the path `data-color="N"` instead of a class and let the existing `[data-color="N"] { --edge-color }` rules apply — prefer this, fewer rules), `.arrow { fill: var(--edge-color, var(--border)); }` with the same `data-color` on the marker path.
- Dragging: `.node` wraps one card now, so a drag moves that card alone; `updated()` keeps clearing inline translates. `revealCard` unchanged. The ResizeObserver redraw and the drag redraw cover edge updates.

- [ ] **Step 1: Implement**, `mix assets.build`, full `mix test` (the SVG defs render is covered by a LiveView assertion: add to `review_live_test.exs` that `#connectors marker#arrow-0 path[data-color="0"]` exists). Read the resulting hook code end to end once for: stale rects after a card is hidden (skip), an edge whose target is the card that contains the call site (recursion: draw from the element's right-middle looping to the card's right edge — acceptable if it renders, must not throw), and performance (one `getBoundingClientRect` per element; fine).
- [ ] **Step 2: Commit** `Edges run from the call site to the callee, coloured and arrowed`.

---

### Task 4: MCP shape, agent prompt, docs

**Files:**
- Modify: `grasp/lib/grasp/mcp/tools/*.ex` moduledocs that describe the reply shape; `grasp/lib/grasp/agent/command.ex` (system prompt); `grasp/test/grasp/mcp/session_tools_test.exs`, `grasp/test/grasp_web/mcp_test.exs`, `grasp/test/grasp/agent/command_test.exs` if it pins prompt text; `README.md`; `docs/specs/2026-09-15-grasp-design.md`

**Requirements:**
- `to_map/1`'s new shape is what every session tool returns; update the tests to assert `edges`/`columns`/`callers`/`callees` and the removed keys are gone. `set_cards` with the same function under two parents yields one card and two edges — add that test. `open_card` on an existing (parent, function) pair still returns the same `card_id`.
- System prompt, step 2 sentence becomes: "Answer with set_cards: one call that lays out the whole flow, roots at the entry points, each callee under the function that calls it, in call order. The same function reached from two callers is one card with two edges — reuse the key. Add a highlight on a card when one call or line range is the point of interest."
- README: the intro and "Reading the code" bullets describe a graph (one card per function; callers open to the left, several at once; `x` closes one card, `Shift+x` the chain; each open call site has a colour and its edge shares it, arrow at the callee); `set_cards` describes "a graph described in one call".
- Spec: rewrite "### Card tree" as "### Card graph" and the automatic-layout paragraphs of "### Layout" (columns by longest path from a source, rows by callers, back-edges ignored, coloured edges from call sites, fit-content cards with `--card-max-width`, drag moves one card). Add to "Known gaps (milestone 4)": the module is still named `Forest` (rename with milestone 8); a card's manual offset no longer carries its callees; rows are not aligned with their callers' rows (a heights-aware pass would need the browser).
- Verify: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (all green), `mix assets.build`. Commit: `Graph shape for MCP replies, prompt and docs`.
