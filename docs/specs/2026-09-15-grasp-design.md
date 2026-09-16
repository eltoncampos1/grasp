# Grasp — call-chain code review for Elixir

## Problem

Reviewing agent-generated Elixir is slow. Editors show one function at a time, following
a call chain means jumping between files, and a unified diff shows changed lines with no
sense of where they sit in the program's flow. As agents write more code than humans can
read this way, review becomes the bottleneck.

Grasp renders a function as a card. Clicking any call inside it opens the callee as a card
to the right, joined to the call site by a coloured edge, so a long chain reads left to
right and several branches can be open at once. One card stands for one function, so a
helper several of them call is read once. Cards show the function's diff against a base
branch. The top level lists the codebase's entry points, and Cmd+K finds any function. An
MCP server lets coding agents arrange cards, annotate them and author guided tours
(next/back with a highlighted call) so the human reviews what the agent wants to explain.

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
- Cards form a **graph**, not a strip: one card per function, with an edge from every
  caller on screen, so several branches are visible side by side and a shared helper is
  read once.
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
   with a target id, kind and range. An event that has a column but no matching node is
   macro-generated (a function component inside `~H`, `use`-injected code) and is kept
   as a `hidden_call`, so the callers/callees graph stays exact even where nothing is
   clickable. Events reported with **no column at all** come from the same machinery but
   are mostly the expansion's own plumbing — a template engine, a query builder,
   `Logger`, `and` and `>` compiling to `:erlang` — which describes how the code was
   built rather than what the function set out to do, and on a real project outnumbers
   the interesting calls by more than ten to one. A column-less event therefore becomes a
   hidden call only when its line falls inside the definition's span and its target is a
   definition the index itself holds. That keeps the calls a `~H` body makes into the
   project's own contexts — the controller to template to context chain — while leaving
   the macro's implementation out. So a call written inside an inline `~H` body reaches
   the graph as a hidden call; a call inside a `.heex` template file compiled by
   `embed_templates` still does not, because the function that template compiles into has
   no definition record for the event to attach to. `defdelegate` is the one column-less
   case placed as a visible call, ranged over the delegate's own name. A `__name__`-shaped
   target (`__schema__/1`, `__struct__/1`, `Phoenix.VerifiedRoutes.__encode_segment__/1`)
   is dropped before any of this, whatever position it carries: it is machinery a macro
   expanded into, and a `~p` sigil reports its encoder at the interpolation's own line and
   column, where the position rules would otherwise make it a clickable call.
4. **Entry points.** After the traced compile, `Application.load/1` then
   `:application.get_key(app, :modules)` gives the application's modules to iterate. Routers are found by their exported
   `__routes__/0` — `use Phoenix.Router` declares no behaviour — and everything else by
   `module_info(:attributes)[:behaviour]`, which is what tells a LiveView from a
   LiveComponent where their injected `__live__/0` does not. Phoenix, LiveView and Oban
   are reached through `apply/3`, so this package never depends on them at compile time.
   A callback becomes an entry point only when the index holds a definition for it:
   `use GenServer` injects default `handle_call/3` and friends that `function_exported?/3`
   reports as present, and a macro-injected `call/2` on an endpoint is the same noise.
   When the application has no module list at all — an unloadable or applicationless
   project — the step reports it on the shell and yields no entry points rather than
   failing the index.
   - `Phoenix.Router`: `Phoenix.Router.routes/1` yields each route. A controller route is
     kind `route` targeting `{plug, plug_opts, 2}`; a LiveView route
     (`plug == Phoenix.LiveView.Plug`, `metadata.phoenix_live_view`) is kind `live_route`
     targeting the first of `mount/3`, `handle_params/3` and `render/1` the index holds,
     since `mount/3` is optional and a route with no reachable callback would otherwise
     vanish; a view writing none of the three falls back to its first indexed function,
     and a view with no indexed function at all is counted and reported on the shell. A
     forward contributes its mount prefix to the forwarded router's routes, which
     `Phoenix.Router.routes/1` reports relative to the mount — composed to a fixed point,
     so a forward inside a forward carries both prefixes — and the forward route itself
     (`verb == :*`) is not an entry. A route whose `plug_opts` is not an action atom is
     skipped, and so is any route whose target the index does not hold, which is what
     drops a forwarded dependency's own controllers. Meta carries `verb`, `path`,
     `router` and `helper`, with nil values dropped.
   - Every other kind takes its callbacks from the behaviour itself
     (`behaviour_info(:callbacks)`, reached through `apply/2` after `Code.ensure_loaded?/1`
     so a behaviour the project does not use costs nothing), minus the callbacks that
     configure a module rather than run its work: `Plug`'s `init/1`, `Oban.Worker`'s
     `new/2`, `backoff/1` and `timeout/1`, `GenServer`'s `code_change/3` and
     `format_status/1,2`, and `Application`'s `config_change/3`. A callback a new version
     of a library adds is therefore picked up without an edit here.
   - `Oban.Worker` carries `queue` and `max_attempts` from `__opts__/0` when they are set.
     `Phoenix.LiveComponent` is a kind of its own, `live_component`. `Plug` is skipped
     when the module is already a route target.

   A route is labelled `VERB /path`; every callback entry is labelled with the function
   id it targets, so the viewer can strip the module it already prints as a heading. The
   list is sorted by kind — route, live route, Oban worker, live view, live component,
   GenServer, supervisor, application, plug — then label, then target. The same pass
   writes each module's behaviours into its `modules[]` entry.
5. **Base ref (PR mode).** With `--base REF`, the merge base of `REF` and `HEAD` is
   resolved first (`git merge-base`, falling back to `REF` itself), and everything is read
   against that `BASE_SHA`: what the branch did, not what has landed on the base since.
   Changed files are `git diff --name-only BASE_SHA` (working tree included) unioned with
   `git ls-files --others --exclude-standard`, filtered to `.ex` sources under the compile
   paths — the same extension the index itself is extracted with, so a changed file can
   never carry base definitions no current record could answer to. Each base version is
   read with `git show BASE_SHA:./path` and run through step 2 only; a file the base did
   not have is compared against an empty source, so its functions read as added.
   Definitions are matched by MFA across the two sides — under any arity a head declares,
   so a function that gains a default argument is matched, not replaced — giving each
   function a `change` of `added`, `modified`, `removed` or `unchanged`; `base_source` is
   stored for modified and removed functions. Removed functions become definitions flagged
   `removed: true` with no calls. A function moved between files without change counts as
   unchanged.
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
      "meta": { "verb": "GET", "path": "/players/:id", "router": "MyAppWeb.Router",
                "helper": "player" } },
    { "kind": "live_route", "label": "GET /players",
      "target": "MyAppWeb.PlayerLive.mount/3",
      "meta": { "verb": "GET", "path": "/players", "router": "MyAppWeb.Router" } },
    { "kind": "oban_worker", "label": "MyApp.Workers.Forex.perform/1",
      "target": "MyApp.Workers.Forex.perform/1",
      "meta": { "queue": "forex", "max_attempts": 3 } },
    { "kind": "live_view", "label": "MyAppWeb.PlayerLive.handle_event/3",
      "target": "MyAppWeb.PlayerLive.handle_event/3", "meta": {} },
    { "kind": "genserver", "label": "MyApp.Cache.init/1",
      "target": "MyApp.Cache.init/1", "meta": {} }
  ]
}
```

`Grasp.Index` (shared reader): `load/1` into a plain struct, `fetch_function/2`,
`callers/2` (reverse index built at load), `callees/2`, `search/3` (substring and
subsequence scoring over `Mod.fun/arity`), `entry_points/1`, `entry_points_for/2` (the
entries a given function is the target of, for the card's badge), `changed_functions/1`,
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
  record, and `.heex` templates are therefore not cards of their own. Milestone 3 narrowed
  the consequence where the generated code sits inside a function that does have a record:
  a call written in an inline `~H` body is kept as a hidden call on the function holding
  it, so a LiveView reaches its context through its own template. A template compiled from
  its own file is still out of reach — see Known gaps (milestone 3).

## Part 2 — `grasp` viewer

```
cd grasp && mix grasp.serve --index ../my_app/.grasp/index.json [--port 4040] [--editor vscode]
```

Binds to 127.0.0.1. Reloads the index when the file's mtime changes (2 s poll) and
broadcasts the reload.

### Session

`Grasp.Session` is a GenServer per named session, found through a Registry. State:

- `cards`: map of card id to `%{function_id, highlight, view, collapsed, offset}` where
  `highlight` is `nil`, `%{call: target_id}` or `%{lines: a..b}`, `view` is `:source` or
  `:diff`, and `offset` is `{dx, dy}` in stage pixels from the card's automatic position
  (`{0, 0}` when untouched). One card per function: a function already on screen is never
  opened twice.
- `edges`: directed caller → callee, each `%{from, to, target, color}` where `target` is
  the caller's own spelling of the call — which identifies the call site inside its body —
  and `color` indexes an eight-entry palette handed out in creation order, so a call site
  and the edge leaving it are painted alike. At most one edge joins a given pair, so mutual
  recursion reads as two.
- `groups`: map of group id to `%{id, title}`, `title` being a string or `nil`, and a card
  carrying the id of the one group it belongs to (`nil` for none). A group is the section
  drawn round cards, with a name over it or without: it changes no edge, hides nothing, and
  a card is in one at a time. A group whose last card leaves, or is closed, is deleted;
  group ids are never reused.
- `focus`: the focused card id.
- `annotations`: keyed by function id, each `%{id, author, body, line}` with author
  `"agent"` or `"human"` and a markdown body.
- `tour`: `nil` or `%{title, steps, position}` where a step is
  `%{function_id, highlight, note, parent_step}`.

Every mutation broadcasts on `session:<name>` and debounce-writes
`<project.root>/.grasp/sessions/<name>.json`. A session loads from disk if the file
exists.

### Card graph

- Clicking a call opens the callee to the right and adds an edge from the call site. A
  card may call many others, so several branches are visible at once.
- A function already on screen is focused and scrolled to rather than opened again, and
  the click leaves an edge from the new caller behind it. A helper three cards call is one
  card with three edges arriving, so reading it once is reading it for every caller.
- The call span stays marked while the callee is open, in the colour its edge carries.
- `x` closes one card: its edges go and what it called stays, unattached. `Shift+x` closes
  it together with everything that had no other way to be reached — a card another visible
  card also calls survives, and so does a card upstream of the closed one that a cycle also
  puts downstream. Collapsing hides what only that card reaches, behind a count badge.
- Opening a caller from the callers menu adds it to the left of the card and joins the
  two; the card itself does not move and keeps every other edge. Several callers may be
  open at once.
- Palette and entry-point selection add a card with no caller. Shift+Enter opens it as a
  callee of the focused card instead.
- MCP `set_cards` replaces the whole graph.

### Layout

A two-dimensional canvas that pans and zooms. The automatic layout is columns: a flex row
of columns, each a vertical stack of cards, so the placement stays pure CSS once the server
has said which column a card belongs to. `Forest.layout/1` computes that. A card nothing
on screen calls is a source and sits in column 0; every other card sits one column right of
the caller that reaches it from furthest right, found by a depth-first walk from the
sources. The walk refuses to re-enter a card already on its own stack, so a recursive or
mutually recursive call names no column and cannot loop for ever; a group of cards that
only call each other has no source at all, so its lowest id is promoted to one until every
card is placed. Within a column, rows follow the callers — column 0 reads in id order, and
every later column is ordered by the mean row of its callers in the column immediately
left, so edges cross as little as possible. A card whose callers all sit further left has
no mean and sorts last, by id.

Cards are laid out one section at a time, a section being a group's cards or, last, the
cards in no group: `Forest.sections/1` runs the column algorithm over one section's cards
at a time, seeing only the edges between them, so a member reached only from another
section heads a column of its own and column indices count from the section's own left
edge. Sections read in group-id order and stack down the stage, each a frame as wide as
its own columns, with an `ungroup` button in its header that dissolves the group
and leaves the cards. A group keeps its section while a collapse hides every member, so
the frame does not blink out of the page; the section for the cards in no group appears
only when a visible card is in none.

A group is a frame round cards; its title is a label on that frame and may be absent. The
forest makes one either way: `new_group/3` frames the cards in hand under a title or under
none and always builds a fresh group, while `group_cards/3` addresses a group by title —
reusing the one already carrying it — and so reaches only a titled group. `rename_group/3`
is what names a group afterwards, and a blank title there clears the name rather than being
refused, so a frame can be drawn first and named once the reader sees what it holds. The id
is what names a group for certain: titles are neither required nor unique.

Groups are made and edited on the canvas as well as over MCP. A frame's title is renamed in
place: clicking it swaps the heading for a form over the same title, Enter saves through
`Session.rename_group/3` — which keeps the group's id and its cards, so an id held elsewhere
still names it, and takes a blank title as a frame left with no name — and Escape or a blur
leaves it as it was. Which frame is being renamed is the LiveView's (`renaming_group`), not
the browser's, so one rename is open at a time and a
patch cannot lose it. A card is put into a group from its own header menu, or by being
dragged into another group's frame: the drag hook finds the frame under the release with
`elementFromPoint`, having taken the dragged node out of hit testing for the lookup, and
sends its group id along with the move. A drop anywhere else — the groupless section, the
bare canvas, the frame the card is already in — is a move and nothing more, so a card never
changes group by being put down near one. A card that does change group keeps the offset the
drag gave it, which was measured against where it sat in its old section, so it is drawn
displaced by that much from its place in the new one until the layout is reset.

A card is as wide as its widest line up to a ceiling (`--card-max-width`, 60rem), rather
than a fixed width, so a column of one-line helpers does not reserve the width of the
widest function in the session. Arrow keys move focus to a caller, a callee or the
neighbour in the same column; `x` closes the focused card, `Shift+x` closes it and
everything that hung off it alone, `c` collapses it.

The canvas pans by dragging empty background, by holding Space and dragging from anywhere
(cards included), or with the wheel; Ctrl or Cmd with the wheel zooms about the cursor. A
toolbar carries the sidebar toggle, zoom out, a zoom readout that resets to 100% when
clicked, fit, zoom in and "reset layout". The view — `{x, y, scale}` — lives only in the
canvas hook and is written to a stylesheet rule for the stage rather than to an inline
style, so a LiveView patch cannot wipe it mid-gesture. A wheel over something that can
scroll itself — a code body scrolled sideways, an open callers menu — is left to that
element.

Zoom out past 0.6 and the canvas reads semantically rather than optically: the hook puts
`grasp-far` on `<body>`, and every card drops its body, its "Also calls" footer and, on a
stub, its prose and its hexdocs link, keeping its header and one line — the function's head.
`Grasp.Highlight.signature/1` renders that head from the same memoised token pieces the body
is built from, so it reads as code rather than as a plain-text label; it carries no gutter
and no call spans, because a call site at that scale is too small to aim at.
`Highlight.signature_line/1` finds the line — the first opening with any of `def`, `defp`,
`defmacro`, `defmacrop`, `defguard`, `defguardp` or `defdelegate`, past whatever `@doc` and
`@spec` sit above it, without the indentation it was written at and without its trailing
`do` — and `CardComponents.signature/1` takes its text for the title a pointer reads. A stub,
or a record with no definition in it, falls back to `Mod.fun/arity`. The header, that line
and a section's header are sized as `--far-size / --zoom` — 14px divided by the scale the
hook writes on the stage beside the transform — so they measure 14px on screen at every zoom
while everything around them shrinks; everything inside the header takes the header's size,
rather than each element keeping a size the zoom has already shrunk past reading. The card's
width floor and ceiling go with the body, leaving each card as wide as the wider of its
header and its signature. The header keeps its badges, its stats and its tint, which is what
marks a removed function, and its buttons stay live, so a far-out card can be closed or
collapsed without zooming back in to it.

Because the class decides how big the cards are, "fit" fits in two passes: the first applies
a scale and so lays out the canvas the second measures. Two passes that land on opposite
sides of the threshold have no fixed point — each scale produces the box the other measured —
so the fit is pinned at the threshold, the one scale both layouts agree on, rather than
alternating between them on repeated presses.

Each card carries a persistent offset from its automatic position, set by dragging its
header or by Ctrl-dragging anywhere on it. The drag shows an inline translate at once and
pushes `move_card` on release; the offset is stored on the card (`Forest.move/3`) and
re-rendered as `--dx`/`--dy` on the node. A drag moves that one card: with a card reachable
from several callers there is no subtree to carry along. "Reset layout"
(`Forest.reset_offsets/1`) clears every offset at once.

Edges are an SVG overlay, not CSS: the hook walks the open call sites, measures each one
and the callee's card, and draws a cubic path between them, so a line follows a card that
has been dragged. A path takes the call site's palette colour and ends in an arrowhead of
the same colour at the callee, so a card with several callers says which of its edges comes
from where. An edge leaves towards the callee and arrives on the side it comes from, so a
caller opened to the right of the card it calls is joined round the outside rather than
through it; a call site scrolled out of the card's clipped body has its start clamped to
the card's border. The overlay sits inside a `phx-update="ignore"` element — the server
renders only the arrowhead markers, which a path cannot carry inline — and its strokes are
non-scaling, so they stay visible at the smallest zoom.

### Page

`GraspWeb.ReviewLive` serves `/` (session `default`) and `/s/:name`. A left sidebar
(`GraspWeb.Sidebar`) starts from the project's entry points, in collapsible groups
ordered from the outside in — Routes (routes and live routes), Background jobs (Oban
workers), Live views (views and components), Processes (GenServers), Supervision
(supervisors and the application), Plugs and Other (any kind the viewer has no group
for) — with Modules last. Which groups arrive open is decided once at mount: the routes
while there are at most fifty of them, the module list when the project has no entry
points at all, nothing otherwise. A group with nothing in it is not rendered, which is
what makes the same sidebar readable in a library and in a web app; a group that is
rendered keeps its body in the DOM when collapsed, hidden, so its title's `aria-controls`
always names an element. Routes are bucketed by the router that declared them and ordered
by path, keeping their `VERB /path` label; every other group buckets its entries by
module, prints the module once as a heading and lists each callback under it as
`fun/arity` alone, with the full id on the row's `title`. Group titles stick to the top while the
list scrolls, and a group's count sits in its title. In PR mode a Changes list grouped by
module with added/modified/removed badges joins them. The canvas fills the rest.

When a tour is active, a bar shows its title, step position, the step's note, and
Back/Next (keys `[` and `]`). A tour step opens its function as a child of the
`parent_step` card, defaulting to the previous step when that function calls it and
otherwise to a new root, then focuses it with the step's highlight.

### Card

- Header: entry-point badges (a route's `VERB /path` in full, since neither the title nor
  the body carries it; the kind for every other kind, spelled as a reader says it — "live
  route", "worker", "GenServer" — since its label is what the title already says),
  `Mod.fun/arity`, `file:line` that opens the `--editor` URL scheme, change badge,
  Source/Diff toggle, callers menu, group menu, collapse, close.
- The group menu lists every group on the canvas, the card's own marked `aria-current`, so
  joining one is picking it by name rather than by id; under them a form makes a new group
  around this card from a title, and a card already in a group can leave it. A stub carries
  the same menu as a function card, since a stub dragged into a frame is in that group like
  any other card and would otherwise have no way out of it. Which card's menu is open is
  server state (`group_menu_open`), as the callers menu is; opening either menu, or a frame
  rename, closes the other two, so one panel stands at a time and a patch cannot drop it.
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
  project's lockfile, which the index does not yet carry. Unchanged by milestone 3.

### Known gaps (milestone 3)

- **Route pipelines are not in the index.** `Phoenix.Router.routes/1` returns the route's
  verb, path, plug, plug options, helper and metadata, but not the pipelines it was
  declared through, so the sidebar cannot group or filter routes by `:browser`, `:api` or
  an auth pipeline. Recovering them means reading the router's own source or a private
  reflection function, neither of which is worth the coupling yet.
- **Template calls into dependencies are not shown.** The column-less rule keeps only
  targets the index holds, so a template's call into the project's contexts appears as a
  hidden call while its call into a dependency's helper — a component library, the HTML
  helpers — does not. The alternative is the ten-to-one flood of expansion internals that
  made the whole class unusable.
- **A `.heex` template file does not reach the call graph.** A call written in an inline
  `~H` body is kept as a hidden call on the function holding it, but a template
  `embed_templates` compiles from its own file becomes a function the extractor never saw,
  so the events for every call it makes are dropped with their caller. Giving those
  generated functions a definition record — the template file as their source — is the
  fix, and it belongs with the extractor rather than the join.
- **`defimpl`, `defprotocol` and definitions nested under a control structure** are still
  invisible to the extractor, so a callback implemented there is neither a card nor an
  entry point. Unchanged from milestone 1.

### Known gaps (milestone 4)

- **One agent run at a time per session.** The CLI takes a single prompt per invocation,
  so the runner refuses a second prompt while one is in flight rather than queueing it.
  Nothing stops a reviewer from opening a second session name and running there.
- **The chat panel needs the Claude Code CLI on the machine.** It is spawned as an
  executable, found on `PATH` as `claude` or named by `GRASP_AGENT_COMMAND` /
  `--agent-command`; `GRASP_AGENT_MODEL` / `--agent-model` picks the model. With no such
  executable the panel reports that and the rest of the viewer is unaffected. A shell
  alias or function is not an executable and will not be found.
- **Transcripts are in memory.** A conversation lives in its runner process, so it
  survives a browser reload and is gone when the viewer stops. Sessions on disk
  (milestone 6) are where a transcript would be persisted, if it is worth persisting.
- **The agent can only read.** Its built-in tools are `Read`, `Grep` and `Glob`, and
  Grasp is its only MCP server, so it cannot edit a file or run a command. That is the
  intended boundary rather than a gap to close: the review loop is arranging cards, not
  changing code.
- **No annotations and no tours.** The agent can open, close, focus and highlight cards,
  which is enough to walk a chain, but it cannot leave a note on a card or author an
  ordered tour a reviewer steps through. Both are later milestones (6 and 7) and both add
  MCP tools rather than changing the ones here.
- **An edge leaving a stub card is not drawn.** An edge is anchored to the call site in
  the caller's rendered source, and a stub card — one standing for a function the index
  does not hold — has no source, so there is nothing for an edge to leave from. A card
  opened from a stub therefore arrives with no line joining it. Both cards are in the graph
  and laid out in columns as usual; only the line is missing.
- **The module is still named `Forest`.** `Grasp.Session.Forest` holds a graph, not a
  forest of trees. The rename waits for milestone 8, where the session's persisted JSON is
  versioned anyway.
- **Dragging a card moves that card alone.** A card reachable from several callers has no
  subtree of its own to carry along, and moving everything downstream of it would drag
  cards that other, untouched callers also point at. So a hand-placed card leaves what it
  calls where the automatic layout put it.
- **Rows are not aligned with their callers' rows.** A column orders its cards by the mean
  row of their callers, which keeps edges from crossing, but it cannot put a callee level
  with the call site that opened it: cards have different heights, and the server lays out
  the columns without knowing any of them. A heights-aware pass would have to run in the
  browser, where the measurements are.
- **`find_paths` is bounded three ways and says so only for one of them.** `max_depth`
  above 8 or `limit` above 20 is a schema violation the call is rejected for, not a value
  clamped down to the cap, so a client that asks for more gets an error to fix rather
  than a silently smaller answer. The third bound, a 20 000-node visit budget, is the one
  that can bite a caller who asked for nothing unusual; an exhausted budget comes back as
  `truncated?: true`, which says the answer is partial but not which part is missing.

### Known gaps (milestone 5)

- **A whitespace-only edit reads as modified.** A function is modified when its text
  differs from the base's, byte for byte, so reformatting or re-indenting it puts it in
  the Changes group with a diff of lines that say the same thing. Comparing the parsed
  forms instead would hide a change to a string literal or a heredoc, which is worse.
- **A rename is a removal and an addition.** A function is identified by
  `Module.name/arity`, so renaming it — or moving it to another module — is a definition
  the base had and this branch does not, plus one the branch has and the base did not. The
  two are not joined, and neither carries the other's source. An arity change is the same,
  with one exception: the two sides are matched under every arity a head declares, so
  adding or dropping a default argument keeps the function joined to its base version.
- **The base side is never compiled, only parsed.** Calls come from the compiler's tracer,
  which runs over the branch alone, so a removed function has no callers and no callees at
  all — its card shows its source and nothing else — and a modified function's calls are
  the ones it makes now. A call the branch deleted is visible in the diff body and nowhere
  in the graph.
- **Uncommitted and untracked work is part of the branch.** Changed files are the ones
  that differ from the merge base *in the working tree*, plus everything git reports as
  untracked, so a review reads the code as it is on disk. Re-running the index after a
  save is what refreshes it; there is no way to ask for the committed state instead.
- **The diff is line-based.** `List.myers_difference/2` over the two sources, one entry
  per line: a line that changed shows as a deletion above an insertion, with no marking of
  which words inside it differ. Both sides are highlighted as code, so a reader compares
  them by eye.

## Part 3 — MCP

Served by `anubis_mcp` at `/mcp` over Streamable HTTP, on the same endpoint as the viewer.
Every session tool takes a `session` name (default `"default"`) and creates that session on
first reference. Results are JSON text content, so any MCP client can read them.

- Read tools: `search_functions(query, limit)`, `get_function(id)` returning the record
  (module, name, arity, kind, file, span, source, calls, hidden calls) plus its callers and
  the entry points that lead to it, `get_callers(id)`, `get_callees(id)`,
  `find_paths(to, from?, max_depth, limit)`, `list_entry_points(kind?, query?, limit)`,
  `list_modules(query?, limit)`, `list_sessions()`.
- `find_paths` walks the call graph (visible and hidden calls) breadth first, shortest
  paths first, and returns at most `limit` distinct paths of at most `max_depth` hops
  (default 6, cap 8). With `from` omitted it walks callers backwards from `to` until it
  reaches an entry-point target, so "which controller or worker reaches this function"
  is one call. Each path is a list of function ids; a path that starts at an entry point
  carries the entry's kind and label. A visit budget bounds the walk on large graphs and
  the result says when it was hit.
- Session tools: `get_session(name)`, `set_cards(name, cards)`, `open_card(name,
  function_id, parent_card_id?, highlight?)`, `close_card(name, card_id)`, `focus_card(name,
  card_id)`, `highlight_card(name, card_id, highlight)`, `group_cards(name, title?,
  card_ids)`, `ungroup_cards(name, card_ids)`, `rename_group(name, group_id, title?)`. Every
  session tool returns the resulting graph as JSON — `focus`, `cards` (each with its id,
  `function_id`, `collapsed`, `highlight`, the `group` it is in and the ids in `callers` and
  `callees`), `edges` (`from`, `to`, the call `target` and the palette `color`), `groups`
  (`id`, `title` — null when the group has none — and the cards in each), `sections` (a
  group id or null, and its columns) and `columns`, the ids in layout order — so the agent
  can address cards it just created and see how they were laid out.
- `group_cards` frames cards already open under a title, creating the group when nothing
  carries that title yet, and `ungroup_cards` takes cards back out. With no title it frames
  them under a group of its own with no name, so an agent that has a set of cards to draw
  apart from the rest need not invent a heading for it. A card belongs to one group, so
  naming it in a second takes it out of the first, and a group left with no cards is
  deleted. An unknown card id is a tool error naming it.
- `rename_group` names a group by its id and changes only its title: the cards stay put and
  the id stands, so a `group` or `sections` entry already quoted still names the same group.
  It is how an untitled frame is given a name and, with the title left out, how a frame
  loses one. An unknown group id is a tool error naming it; the title is stored trimmed,
  since `group_cards` matches one exactly. Titles are neither required nor unique — a rename
  may give two groups the same one, and `group_cards` and `set_cards`, which address a group
  by title, then reach whichever was made first — so the id is the only handle that names
  one group for certain. The forest carries the operations this is built on — `new_group/3`,
  which always makes a fresh group, titled or not, `rename_group/3` and `add_to_group/3`,
  which joins cards to a group by id rather than by title and creates none — and the
  viewer's manual grouping drives the same ones.
- `set_cards` replaces the graph. `cards` is a flat list of `{key, function_id,
  parent_key?, group?, highlight?}`; `group` is a title rather than an id, so entries
  sharing one land in the same group and the groups are created in the order their titles
  first appear — one `set_cards` call lays out several flows, each in its own frame; `key` is any string the caller picks, `parent_key` names
  another entry, and entries are applied in order so a caller precedes what it calls. Two
  entries naming the same function describe one card with an edge from each caller, so a
  helper listed under each of its callers is drawn once. Unknown function ids or dangling
  parent keys make the whole call a tool error that names them, and the graph is left
  untouched. An edge from `set_cards` or `open_card` carries the caller's own spelling of
  the call when such a call exists, so the coloured edge and the marked call span render as
  if a human clicked.
- A highlight is `{call: target_id}` or `{lines: [first, last]}`. The card renders the
  highlighted call with a ring, or the highlighted lines with a tinted background, and the
  canvas reveals it when the card gains focus. A highlight stays until replaced or the
  card closes.
- PR mode adds two tools. `list_changes()` answers `total`, the `base_ref` the index was
  built against (`null` without one) and the changed functions sorted by id, each with its
  `id`, `change`, `file`, `line` and `module` — the first call of a pull-request review,
  from which each id is traced to its entry points with `find_paths`. `set_view(name,
  card_id, view)` shows a card as its `"source"` or its `"diff"` and answers the graph like
  every other session tool; only a modified function has two sides, so a diff of anything
  else is a tool error naming the function.
- Later milestones add `annotate`, `set_tour`/`tour_goto`, resources and the
  `build_review_tour` prompt.

Registering in Claude Code:

```
claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
```

### Chat panel

The viewer can drive an agent itself, so a reviewer types "show me the award bonus flow"
and watches the cards arrive. The panel is a server-owned dock over the canvas (toggle
with Cmd+I or the toolbar button) with a transcript, a prompt box, Send, Stop and New
conversation.

- `Grasp.Agent.Runner` is a GenServer per session name. On a prompt it spawns the Claude
  Code CLI headless (`claude -p PROMPT --output-format stream-json --verbose`) with the
  indexed project's root as its working directory, Grasp registered as its only MCP server
  (`--strict-mcp-config --mcp-config {"mcpServers":{"grasp":{"type":"http","url":
  ".../mcp"}}}`), built-in tools limited to `Read Grep Glob`, and `mcp__grasp Read Grep
  Glob` pre-approved through `--allowedTools`, so it never edits files or runs commands.
  The appended system prompt names the viewer session and tells the agent to discover with
  the read tools and answer with `set_cards`, starting at entry points and reusing one card
  for a function two callers reach. Follow-up prompts pass `--resume <session_id>` (taken
  from the stream's `system/init` event), and New conversation drops that id. The command
  is configurable (`:grasp, :agent_command`, default `claude`) so tests substitute a
  script.
- The panel offers the model the CLI runs with: `Grasp.Agent.models/0` — `haiku`, `sonnet`,
  `opus`, `fable` — plus a default entry that leaves the choice to `:agent_model`
  (`--agent-model` / `GRASP_AGENT_MODEL`) or, failing that, to the CLI itself.
  `Grasp.Agent.set_model/2` records the pick on the runner, which reads it when it builds
  the next command, so a live run is not disturbed and New conversation keeps the pick while
  dropping the transcript. A name the facade does not know is refused rather than passed to
  the CLI; the select cannot offer one.
- The runner parses the JSON stream line by line: `assistant` text blocks stream into the
  transcript, `tool_use` blocks become tool rows showing the tool name and its main
  argument, `tool_result` blocks mark the row done or failed, `system/init` records the
  session id and reports when the `grasp` MCP server is not connected, and `result`
  closes the run with its cost. Lines that are not JSON (stderr is merged) are kept as a
  log shown when the run fails. Stop kills the OS process. One run at a time per session;
  a second prompt while running is refused.
- The runner broadcasts its transcript on `agent:<name>`; `ReviewLive` subscribes, so
  every tab on the session sees the same conversation, and card changes arrive through
  the ordinary session broadcast because the agent went through MCP like any other client.

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
  `Phoenix.LiveViewTest` covers: clicking a call opens the callee to its right, clicking it
  again focuses the card already there, the same function reached from two callers being one
  card with two edges, closing a card and closing a chain, opening a caller to the left,
  palette search and Enter, the diff toggle, tour next/back highlighting the step's call,
  and annotation rendering. `Grasp.Session` has a persistence round-trip test. MCP is
  tested as JSON-RPC over `/mcp` with `Phoenix.ConnTest`: initialize, tools/list, then
  `set_cards` followed by an assertion that the LiveView re-rendered.
- CI: GitHub Actions on Elixir 1.20 / OTP 29 for both packages: format check, compile
  with warnings as errors, tests.

## Milestones

1. Repo scaffold and `grasp_index` steps 1 to 3 and 6: definitions, calls, JSON. Run it
   on a real Phoenix project. Done.
2. Viewer: load the index, card graph with click-to-open, highlighting, palette. Done.
   - Milestone 2.1 went back over the viewer: Lumis highlighting with the `github_light`
     theme, the GitHub Light palette and denser 60rem cards, per-card layout offsets in
     the session, and a canvas that pans, zooms, drags cards and draws its own
     connectors. Routers and entry points are unchanged — they remain milestone 3.
3. Entry points: index step 4 and the sidebar. Done.
   - The sidebar now starts from entry points rather than from the module list, cards
     carry an entry badge, and the join keeps a template's calls into the project as
     hidden calls, so a controller reaches its context through its template. Route
     pipelines are the one thing step 4 set out to carry and could not.
4. MCP tools and the chat panel: read tools, `find_paths`, card tools with highlights,
   Streamable HTTP at `/mcp`, and the in-viewer agent runner. The agent proves the
   arrangement loop before PR mode and tours build on it.
5. PR mode: base ref extraction, change badges, Changes sidebar, diff view, `list_changes`.
6. Sessions on disk: persistence, annotations UI and `annotate`.
7. Tours: `set_tour`, `tour_goto`, the tour bar, resources and the `build_review_tour`
   prompt.
8. README for strangers, CI, editor links, `mix grasp.serve` polish.

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
