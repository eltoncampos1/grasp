# Grasp — call-chain code review for Elixir

## Problem

Reviewing agent-generated Elixir is slow. Editors show one function at a time, following
a call chain means jumping between files, and a unified diff shows changed lines with no
sense of where they sit in the program's flow. As agents write more code than humans can
read this way, review becomes the bottleneck.

Grasp renders a function as a card. Clicking any call inside it opens the callee as a
child card to the right, so a long chain reads left to right and several branches can be
open at once. Cards show the function's diff against a base branch. The top level lists
the codebase's entry points, and Cmd+K finds any function. An MCP server lets coding
agents arrange cards, annotate them and author guided tours (next/back with a
highlighted call) so the human reviews what the agent wants to explain.

## Decisions

- Standalone repository at `~/repos/grasp`, open source from day one (Apache-2.0).
- Two independent Mix projects, not an umbrella. `grasp_index` is the indexer a target
  project adds as a dev dependency; `grasp` is the Phoenix LiveView viewer plus MCP
  server and is never a dependency of the target.
- Call resolution comes from an **Elixir compiler tracer** (exact, the mechanism behind
  `mix xref` and Boundary), with **Sourceror** supplying definition spans and call ranges.
  Reach was evaluated and rejected as the engine: its source-level resolution misses
  what macros inject, and it is a large fast-moving dependency of which only a slice
  would be used.
- PR mode diffs against a **local git base ref**. The base side is Sourceror-parsed
  only; it is never recompiled.
- MCP over **Streamable HTTP** at `/mcp` on the same endpoint as the UI, via
  `anubis_mcp ~> 2.0`.
- Sessions and tours persist as **JSON files** under `.grasp/sessions/` in the target
  repository, so agents can write them and they can travel with a PR.
- Cards form a **tree**, not a strip: a card can have many children so multiple
  branches are visible side by side.
- Highlighting by **Lumis** (tree-sitter) with the `github_light` theme; the whole UI
  uses the GitHub Light palette.
- Entry points in v1: Phoenix routes (controller actions and LiveView routes), Oban
  workers, LiveView and LiveComponent callbacks, GenServer, Supervisor, Application and
  Plug callbacks.
- Toolchain pinned to Elixir 1.20.4 / OTP 29 (`.mise.toml`); `grasp_index` requires
  Elixir `~> 1.19` (for `test_ignore_filters`).

## Repository layout

```
grasp/
  README.md  LICENSE  .mise.toml  .github/workflows/ci.yml  docs/specs/
  grasp_index/   # hex-publishable. Deps: sourceror, jason. Mix task, tracer, extraction,
                 # entry-point detection, git base diff, Grasp.Index reader (shared).
  grasp/         # Phoenix LiveView viewer + MCP. Deps: phoenix, phoenix_live_view ~> 1.2,
                 # bandit, jason, lumis, lazy_html, anubis_mcp ~> 2.0,
                 # {:grasp_index, path: "../grasp_index"}
```

## Part 1 — `grasp_index`

In the target project:

```elixir
{:grasp_index, "~> 0.1", only: :dev, runtime: false}
```

```
mix grasp.index [--base main] [--out .grasp/index.json]
```

### Pipeline

1. **Trace compile.** Register `Grasp.Index.Tracer` via
   `Code.put_compiler_option(:tracers, ...)`, enable `parser_options: [columns: true]`,
   then `Mix.Task.run("compile", ["--force"])`. The tracer records into ETS, for the
   events `:remote_function`, `:local_function`, `:imported_function`, `:remote_macro`,
   `:imported_macro` and `:local_macro`: caller file, caller `{module, function, arity}`
   from `env`, line, column, callee MFA and event kind. Events fired outside a function
   body (`env.function == nil`) are dropped. Only files under the project's
   `elixirc_paths` are kept, so dependencies are excluded.
2. **Extract definitions with Sourceror.** For each source file: parse, walk `defmodule`
   with a module stack (nested modules resolve to their full name), and collect
   `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, `defguardp` and `defdelegate`
   clauses grouped by `{module, name, arity}`. A head with default arguments registers
   every arity it defines, all pointing at the one definition. The span runs from the
   first attached attribute or leading comment (`@doc`, `@spec`, `@impl`) through the
   last clause's `end`; the source text is the file slice for that span. Every call node
   inside the bodies is collected with `Sourceror.get_range/1`, keyed by start
   line and column.
3. **Join.** Each tracer event finds its definition by caller MFA (falling back to
   file and line containment) and its call node by line and column, producing a call
   with a target id, kind and range. Events with no matching node are macro-generated
   (function components inside `~H`, `use`-injected code) and are kept as
   `hidden_calls`, so the callers/callees graph stays exact even where nothing is
   clickable.
4. **Entry points.** After `Mix.Task.run("loadpaths")`, iterate the application's
   modules (`:application.get_key(app, :modules)`) and read
   `module_info(:attributes)[:behaviour]`:
   - `Phoenix.Router`: `Phoenix.Router.routes/1` yields each route with verb, path and
     pipelines. Controller routes target `{plug, plug_opts, 2}`. LiveView routes
     (`plug == Phoenix.LiveView.Plug`, `metadata.phoenix_live_view`) target the view's
     `mount/3`.
   - `Oban.Worker`: `perform/1`, with queue and max attempts from `__opts__/0`.
   - `Phoenix.LiveView` and `Phoenix.LiveComponent`: exported callbacks among
     `mount/3`, `handle_params/3`, `handle_event/3`, `handle_info/2`, `handle_async/3`,
     `update/2`, `render/1`.
   - `GenServer`: `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`,
     `handle_continue/2`, `terminate/2`. `Supervisor`: `init/1`. `Application`:
     `start/2`. `Plug`: `call/2`, skipped when the module is already a route target.
5. **Base ref (PR mode).** With `--base REF`, changed files come from
   `git diff --name-only REF` (working tree included) filtered to `.ex` and `.exs`. Each
   base version is read with `git show REF:path` and run through step 2 only.
   Definitions are matched by MFA across the two sides, giving each function a `change`
   of `added`, `modified`, `removed` or `unchanged`; `base_source` is stored for modified
   and removed functions. Removed functions become definitions flagged `removed: true`
   with no calls. A function moved between files without change counts as unchanged.
6. **Write JSON** to `--out`.

### Index JSON (version 1)

```jsonc
{
  "version": 1,
  "generated_at": "2026-09-15T10:00:00Z",
  "project": { "app": "my_app", "root": "/abs/path", "elixirc_paths": ["lib"] },
  "git": { "head": "sha", "branch": "...", "base_ref": "main", "base_sha": "sha" }, // null outside git
  "modules": [
    { "name": "MyApp.Wallets", "file": "lib/my_app/wallets.ex", "line": 1, "behaviours": ["GenServer"] }
  ],
  "functions": [
    {
      "id": "MyApp.Wallets.credit/3",
      "module": "MyApp.Wallets", "name": "credit", "arity": 3, "arities": [2, 3],
      "kind": "def", "file": "lib/my_app/wallets.ex",
      "span": { "start_line": 40, "end_line": 62 },
      "source": "@doc ...\ndef credit(...)",
      "calls": [
        { "target": "MyApp.Ledger.post/2", "kind": "remote",
          "range": { "start": [45, 5], "end": [45, 22] } }
      ],
      "hidden_calls": [ { "target": "MyAppWeb.CoreComponents.button/1", "kind": "remote", "line": 50 } ],
      "change": "modified", "base_source": "...", "removed": false
    }
  ],
  "entry_points": [
    { "kind": "route", "label": "GET /players/:id",
      "target": "MyAppWeb.PlayerController.show/2",
      "meta": { "verb": "GET", "path": "/players/:id", "pipelines": ["browser"] } },
    { "kind": "oban_worker", "label": "MyApp.Workers.Forex",
      "target": "MyApp.Workers.Forex.perform/1", "meta": { "queue": "forex" } },
    { "kind": "live_view", "label": "MyAppWeb.PlayerLive",
      "target": "MyAppWeb.PlayerLive.mount/3", "meta": {} },
    { "kind": "genserver", "label": "MyApp.Cache", "target": "MyApp.Cache.init/1", "meta": {} }
  ]
}
```

`Grasp.Index` (shared reader): `load/1` into a plain struct, `fetch_function/2`,
`callers/2` (reverse index built at load), `callees/2`, `search/3` (substring and
subsequence scoring over `Mod.fun/arity`), `entry_points/1`, `changed_functions/1`,
`modules/1`. The struct is immutable and large — roughly 10 MB of JSON for a 500-file
project — so the viewer stores the loaded index in `:persistent_term`. That keeps the
term off-heap, so every LiveView process reads it without copying; re-loading an index
replaces the term.

### Known gaps (milestone 1)

Edges the indexer does not yet produce. All are planned follow-ups, not design
decisions — the join is only as complete as the definitions the extractor finds, and a
tracer event whose caller has no definition record is dropped entirely.

- **`defimpl` and `defprotocol` bodies.** The extractor walks `defmodule` only, so the
  functions inside a protocol or an implementation get no definition record and their
  tracer events are dropped.
- **Definitions nested under a control structure.** A `def` written inside `if`, `for`,
  `case` or `quote` in a module body is invisible to the extractor for the same reason.
- **Macro-generated functions.** A function a macro defines — `embed_templates`, the
  `def`s a `use` injects — has no source of its own to extract, so it has no definition
  record. `.heex` templates therefore contribute nothing to the graph yet, and the
  controller → template → component chain is severed at the template.

## Part 2 — `grasp` viewer

```
cd grasp && mix grasp.serve --index ../my_app/.grasp/index.json [--port 4040] [--editor vscode]
```

Binds to 127.0.0.1. Reloads the index when the file's mtime changes (2 s poll) and
broadcasts the reload.

### Session

`Grasp.Session` is a GenServer per named session, found through a Registry. State:

- `roots`: ordered card ids in column zero.
- `cards`: map of card id to `%{function_id, parent_id, children, opened_by,
  highlight, view, collapsed, offset}` where `opened_by` is the call target that opened
  the card, `highlight` is `nil`, `%{call: target_id}` or `%{lines: a..b}`, `view` is
  `:source` or `:diff`, and `offset` is `{dx, dy}` in stage pixels from the card's
  automatic position (`{0, 0}` when untouched).
- `focus`: the focused card id.
- `annotations`: keyed by function id, each `%{id, author, body, line}` with author
  `"agent"` or `"human"` and a markdown body.
- `tour`: `nil` or `%{title, steps, position}` where a step is
  `%{function_id, highlight, note, parent_step}`.

Every mutation broadcasts on `session:<name>` and debounce-writes
`<project.root>/.grasp/sessions/<name>.json`. A session loads from disk if the file
exists.

### Card tree

- Clicking a call opens the callee as a child of that card. A card may have many
  children, so several branches are visible at once.
- Clicking a call whose child is already open focuses that child and scrolls to it. The
  call span stays marked while its child is open.
- Closing a card closes its subtree. Collapsing hides the subtree behind a count badge.
- Opening a caller from a root card's callers menu re-parents: the caller becomes a new
  root with the card as its child. From a non-root card, it opens a new root tree of
  caller then function.
- Palette and entry-point selection append a new root. Shift+Enter opens as a child of
  the focused card instead.
- MCP `set_cards` replaces the whole forest.

### Layout

A two-dimensional canvas that pans and zooms. A node renders as a horizontal flex of the
card followed by a vertical stack of its child nodes, recursively, so the automatic layout
is pure CSS. Cards have a fixed width (`--card-width`, 60rem) so every depth starts at the
same x. Each subtree hangs from its parent's top edge and roots stack vertically in column
zero. Arrow keys move focus to parent, child or sibling; `x` closes and `c` collapses the
focused card.

The canvas pans by dragging empty background, by holding Space and dragging from anywhere
(cards included), or with the wheel; Ctrl or Cmd with the wheel zooms about the cursor. A
toolbar carries the sidebar toggle, zoom out, a zoom readout that resets to 100% when
clicked, fit, zoom in and "reset layout". The view — `{x, y, scale}` — lives only in the
canvas hook and is written to a stylesheet rule for the stage rather than to an inline
style, so a LiveView patch cannot wipe it mid-gesture. A wheel over something that can
scroll itself — a code body scrolled sideways, an open callers menu — is left to that
element.

Each card carries a persistent offset from its automatic position, set by dragging its
header or by Ctrl-dragging anywhere on it. The drag shows an inline translate at once and
pushes `move_card` on release; the offset is stored on the card in the session forest
(`Forest.move/3`) and re-rendered as `--dx`/`--dy` on the node, so a dragged card takes its
subtree with it. Re-parenting a card resets its offset, and "reset layout"
(`Forest.reset_offsets/1`) clears every offset at once.

Connectors are an SVG overlay, not CSS: the hook measures each parent and child card and
draws a cubic path between their header ports, so a line follows a card that has been
dragged. The overlay sits inside a `phx-update="ignore"` element — the server never renders
a connector — and its strokes are non-scaling, so they stay visible at the smallest zoom.

### Page

`GraspWeb.ReviewLive` serves `/` (session `default`) and `/s/:name`. A left sidebar lists
entry points grouped by kind, collapsible, and in PR mode a Changes list grouped by
module with added/modified/removed badges. The canvas fills the rest. When a tour is
active, a bar shows its title, step position, the step's note, and Back/Next (keys `[`
and `]`). A tour step opens its function as a child of the `parent_step` card, defaulting
to the previous step when that function calls it and otherwise to a new root, then
focuses it with the step's highlight.

### Card

- Header: `Mod.fun/arity`, `file:line` that opens the `--editor` URL scheme, change
  badge, Source/Diff toggle, callers menu, collapse, close.
- Body: Lumis-highlighted source. Every resolved call is wrapped in a clickable span.
  The highlighted call gets a ring and is scrolled into view. Calls with an open child
  are marked. Calls to functions outside the index (deps, stdlib) render muted and open
  a stub card linking to hexdocs.
- Footer: "Also calls" for hidden calls, then annotations with author badges and an
  add-annotation form.

### Highlighting and diffs

Lumis (tree-sitter) runs server-side. `Lumis.highlight/2` with the `:html_linked` formatter
returns one `div` per source line whose children are nested `span.l-*` runs; the HTML is
parsed into text runs, each carrying the class of its innermost span and a start column, so
a run can be split at a call range's boundary and the pieces inside a range wrapped in one
clickable span. The theme is `github_light`, inlined into the root layout at compile time
from `Lumis.Theme.build_css!/1`; the rest of the UI uses the same GitHub Light palette.

tree-sitter is super-linear on deeply nested binary-operator trees — a twenty-step `|>`
pipeline parses in tens of milliseconds, a forty-step one in hundreds — and a card
re-renders on every LiveView pass, so the parse is memoised per function id in an ETS
table. The table is owned by `Grasp.IndexStore`, which clears it on every index reload: a
cached piece list carries absolute line numbers, so a stale entry would outlive the span it
was computed for. Only the source-derived pieces are cached; the range split and the call
wrapping depend on the card and on which of its calls are open, and stay per render.

The diff view runs `List.myers_difference/2` over the lines of `base_source` and
`source` and renders a unified diff with gutters. "After" lines keep their clickable
calls; removed lines are highlighted only. Removed functions show their base source in a
red-tinted card.

### Command palette

A JS hook opens a `<dialog>` on Cmd+K or Ctrl+K. The input's debounced `phx-change`
drives `Grasp.Index.search/3`; arrow keys move the selection client-side, Enter opens as a
new root, Shift+Enter as a child of the focused card. Results show id, def/defp, change
badge and file.

### Assets

esbuild bundles the three hooks (palette, keys, canvas). Styling is one hand-written CSS
file of custom properties over the GitHub Light palette, plus the Lumis theme stylesheet
inlined in the root layout. No Tailwind. `lazy_html` is a runtime dependency, not a
test-only one: it parses Lumis' HTML on every highlight the cache misses.

### Known gaps (milestone 2)

- **hexdocs links only reach the standard library.** A call target outside the index
  opens a stub card, and the stub links to hexdocs only when the module is loaded in the
  viewer's own VM and belongs to one of the applications Elixir ships. The target
  project's dependencies are not loaded there, so a call into one opens a stub with no
  link. Resolving a dependency's package and version would mean reading the target
  project's lockfile, which the index does not yet carry.

## Part 3 — MCP

Served by `anubis_mcp` at `/mcp` over Streamable HTTP. A session is created on first
reference.

- Read tools: `search_functions(query, limit)`, `get_function(id)` returning source,
  file, span, calls, callers, change and base source, `get_callers(id)`,
  `get_callees(id)`, `find_paths(from, to, max_depth)` (breadth-first search over the
  call graph, for building tours), `list_entry_points(kind?)`, `list_changes()`,
  `list_modules()`.
- Session tools: `list_sessions()`, `get_session(name)`, `set_cards(name, forest)`
  where a node is `{function_id, highlight?, children}`,
  `open_card(name, function_id, parent_card_id?, highlight?)`, `close_card(name, card_id)`,
  `focus_card(name, card_id)`, `annotate(name, function_id, body, line?)`,
  `clear_annotations(name, function_id?)`, `set_tour(name, title, steps)`,
  `tour_goto(name, position)`, `clear_tour(name)`, `reload_index()`.
- Resources: `grasp://function/{id}`, `grasp://entry-points`, `grasp://changes`.
- Prompt `build_review_tour`: instructs an agent to read `list_changes`, trace each
  change to its entry point with `find_paths`, and author a tour with annotations.

Registering in Claude Code:

```
claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
```

## Testing

- `grasp_index`: a fixture project at `test/fixtures/sample_app` with phoenix,
  phoenix_live_view and oban as deps (no database, nothing started) containing a router,
  a controller, a LiveView, an Oban worker, a GenServer, nested modules, default
  arguments, multi-clause functions, a `~H` function-component call, and calls through
  an alias and an import. An integration test runs `mix grasp.index` in the fixture as a
  subprocess and asserts on the JSON. Unit tests cover Sourceror extraction, the tracer
  to range join, and the git base diff against a temporary git repository built in the
  test.
- `grasp`: a committed fixture `index.json` generated from the sample app.
  `Phoenix.LiveViewTest` covers: clicking a call opens a child card, clicking it again
  focuses the existing child, closing a card removes its subtree, opening a caller from a
  root re-parents, palette search and Enter, the diff toggle, tour next/back highlighting
  the step's call, and annotation rendering. `Grasp.Session` has a persistence
  round-trip test. MCP is tested as JSON-RPC over `/mcp` with `Phoenix.ConnTest`:
  initialize, tools/list, then `set_cards` followed by an assertion that the LiveView
  re-rendered.
- CI: GitHub Actions on Elixir 1.20 / OTP 29 for both packages: format check, compile
  with warnings as errors, tests.

## Milestones

1. Repo scaffold and `grasp_index` steps 1 to 3 and 6: definitions, calls, JSON. Run it
   on a real Phoenix project.
2. Viewer: load the index, card tree with click-to-open, highlighting, palette.
   - Milestone 2.1 went back over the viewer: Lumis highlighting with the `github_light`
     theme, the GitHub Light palette and denser 60rem cards, per-card layout offsets in
     the session, and a canvas that pans, zooms, drags cards and draws its own
     connectors. Routers and entry points are unchanged — they remain milestone 3.
3. Entry points: index step 4 and the sidebar.
4. PR mode: base ref extraction, change badges, Changes sidebar, diff view.
5. Sessions: GenServer, persistence, annotations UI.
6. MCP tools, resources, tours and the tour bar.
7. README for strangers, CI, editor links, `mix grasp.serve` polish.

## Verification

- `mix grasp.index --base main` in a Phoenix project produces `.grasp/index.json`; a
  known chain (controller action to context to `Repo`) resolves with ranges.
- `mix grasp.serve` at http://127.0.0.1:4040: click through a four-deep chain, open a
  second branch from the same card, Cmd+K to a function, toggle diff on a modified
  function.
- From Claude Code with the MCP registered: `set_cards` and `set_tour`, watch the browser
  update live, reload the page and confirm the session file restored it.
- Both packages pass `mix format --check-formatted`, `mix compile --warnings-as-errors`
  and `mix test`.
