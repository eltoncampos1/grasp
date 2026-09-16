# Grasp

Call-chain code review for Elixir.

Grasp renders a function as a card. Click any call inside it and the callee opens as a
card to the right, joined to it by an edge that takes the call site's colour and arrows
into the callee, so a deep call chain reads left to right instead of as a series of editor
jumps. The canvas holds one card per function: a helper three functions call is drawn
once, with an edge arriving from each of them, so reading it once is reading it for every
caller. The cards sit on a canvas that pans, zooms and lets you drag a card anywhere you
want it. A sidebar lists the codebase's entry points — Phoenix routes and LiveView routes,
Oban workers, LiveView and LiveComponent callbacks, GenServer, supervisor, application and
plug callbacks — so a review starts where the system starts, with the module list a group
below. A card wears a badge for the entry point it is, a card's callers menu opens the
chain the other way, Cmd+K finds any function, and every card links its `file:line` into
your editor.

A coding agent can drive the same canvas over MCP: it searches the index, traces the
paths into a function, and lays the cards out for the human reviewer. The viewer can run
that agent for you from a panel beside the canvas.

Indexed against a base branch, the same canvas reviews a pull request: the sidebar leads
with what the branch changed, and a modified card swaps between its source and its diff.

Planned: sessions saved to disk, and annotations and guided tours the agent can author.

Grasp exists because agents now write more code than humans can comfortably review with
a text editor and a unified diff.

## Layout

- `grasp_index/` — the indexer. Added to a target project as a dev dependency;
  `mix grasp.index` writes a JSON index of every function, its resolved calls, and the
  project's entry points.
- `grasp/` — the viewer. A Phoenix LiveView app that serves the index as a card canvas.

See `docs/specs/2026-09-15-grasp-design.md` for the design.

## Quick start

In the project you want to review:

```elixir
# mix.exs
{:grasp_index, path: "/path/to/grasp/grasp_index", only: :dev, runtime: false}
```

```
mix deps.get && mix grasp.index
```

Then, from this repo:

```
cd grasp && mix setup && mix grasp.serve --index /path/to/project/.grasp/index.json --editor vscode
```

Open http://127.0.0.1:4040, pick an entry point (or a module) in the sidebar or press
⌘K, and click any call inside a card to open the callee next to it.

## Gestures

- Drag a card by its header to move it, or hold Ctrl and drag from anywhere on it. Ctrl
  and press over a card is the drag gesture, so the context menu is suppressed there;
  a plain right-click still opens it.
- Drag the background to pan; hold Space to pan from anywhere, cards included.
- ⌘ or Ctrl with the wheel zooms about the cursor; the wheel alone pans, except over
  something that can scroll itself.
- ⌘0 resets the canvas zoom, as does clicking the zoom percentage in the toolbar. Some
  browsers also take ⌘0 for their own page zoom, and reset both.
- Below 60% the cards stop shrinking and start summarising: body, badges and tools go, and
  each card shows only the function's signature, scaled back up so it reads at any zoom.
- ⌘M toggles the sidebar. On macOS the browser may take ⌘M for "minimise window", in
  which case use ⌘\\.
- A card's callers menu opens a caller to its left; open several and the card keeps one
  edge from each of them.
- Arrow keys walk the graph, `x` closes the focused card, `Shift+x` closes it together
  with everything that had no other way to be reached, `c` collapses it, ⌘K opens the
  palette.
- **A group of cards is drawn as a titled frame** of its own, laid out from its own left
  edge, so two flows on one canvas are read apart rather than run together. The frame's
  header carries the title, how many cards are in it, and `ungroup`, which takes the frame
  away and leaves the cards where they were. Cards in no group make a last, untitled
  section under the framed ones. Groups are made over MCP — an agent asked for several
  flows gives each one its own.

## PR mode

Index against a base ref and the review becomes a pull request:

```
mix grasp.index --base main
```

The index then records, for every function, whether the branch left it alone, modified it,
added it, or removed it, along with the base version of each modified function's source.
Comparison is against the merge base of `HEAD` and the ref, so a base branch that has
moved on since the branch started does not make every file look touched. Uncommitted and untracked
work counts as part of the branch, so a review reads the code as it is on disk rather than
as it was last committed.

In the viewer:

- **Changes** is the first group in the sidebar, open on arrival, listing every changed
  function under its module with an `added` / `modified` / `removed` badge. Clicking one
  opens it as a card, from which the call chain opens as usual. The line under the project
  name says what the review is against, `main…feature`.
- **A card wears its badge too**, and a modified one counts its lines (`+3 −1`) beside the
  title. The palette carries the same badge, so a search says which hits are part of the
  change.
- **`diff` in a modified card's header** swaps its body for the diff against the base —
  deleted lines from the base, inserted lines from the branch, highlighted as code either
  way — and `source` swaps it back. The `d` key does the same to the focused card, and
  passes over a card with nothing to compare.
- **A removed function opens as a card of its own**, tinted and showing the source the base
  had. Its `file:line` is the base commit's, so it is printed rather than linked into your
  editor.

## MCP

The viewer serves an MCP endpoint at `/mcp` on the same port as the page, over Streamable
HTTP. An agent connected to it reads the index and arranges the cards the human is looking
at. Register it with Claude Code:

```
claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
```

Only requests addressed to loopback are served: the endpoint checks the `Host` it was
asked for and the `Origin` the browser declares, so a page on someone else's domain cannot
reach it even if its DNS points at `127.0.0.1`.

Reading the code:

- `search_functions(query, limit)` — find functions by name. An exact `Module.fun/arity`
  ranks first, then ids containing the query, then a fuzzy match, so `walcre` still finds
  `SampleApp.Wallets.credit/3`.
- `get_function(id)` — one function's source, span, calls, callers, callees and the entry
  points that reach it.
- `get_callers(id)` / `get_callees(id)` — one hop up or down the call graph.
- `find_paths(to, from?, max_depth, limit)` — shortest call paths down to a function, from
  another function or, with `from` omitted, from whatever entry points reach it. Each path
  reads in call order and carries the entry point it starts at.
- `list_entry_points(kind?, query?, limit)` — routes, LiveView and GenServer callbacks,
  Oban workers, each with the function it dispatches to.
- `list_modules(query?, limit)` — modules with their file and the behaviours they
  implement.
- `list_sessions()` — the review sessions the viewer is running.
- `list_changes()` — every function the branch added, modified or removed, with the base
  ref it was compared against. The first call of a pull-request review: each id it returns
  can be traced to its entry points with `find_paths`.

Arranging the cards:

- `get_session(name)` — every open card with what it calls and is called by, the edges
  between them, the columns they are laid out in, what each points at, and which card has
  focus. The ids it returns are what the other card tools address. Every session tool
  answers in this shape.
- `set_cards(name, cards)` — replace the whole canvas with a graph described in one call.
  Each card is `{key, function_id, parent_key?, group?, highlight?}`; a card hangs under an
  earlier one by naming its `key`, and two entries naming the same function are one card
  with an edge from each. `group` is a title: cards sharing one are framed together under
  it, which is how several flows land on one canvas without running together. Nothing
  changes unless every card is good.
- `open_card(name, function_id, parent_card_id?, highlight?)` — add one card, called by
  another or standing on its own. A function already on screen gains an edge instead of a
  second card.
- `close_card(name, card_id)` — close one card and the edges touching it.
- `focus_card(name, card_id)` — scroll a card into view, to say "look here".
- `highlight_card(name, card_id, highlight)` — point at one call inside a card, or shade a
  range of its lines.
- `group_cards(name, title, card_ids)` — frame cards already open under a title, creating
  the group when nothing carries that title yet. A card belongs to one group, so naming it
  here takes it out of the one it was in, and a group left with no cards is gone.
- `ungroup_cards(name, card_ids)` — take cards out of their groups, back to the untitled
  section.
- `set_view(name, card_id, view)` — show a card as its `source` or as its `diff` against
  the base, to point at what the branch did to a function rather than at the function.
  Only a modified function has a diff; asking for one of anything else is an error.

A session name defaults to `default`, which is the canvas at `/`; any other name is the
canvas at `/s/<name>` and is created on first mention.

Arranging a flow, end to end. Asked "show me what happens when SampleApp accepts an
order", an agent calls `list_entry_points(query: "order")` to find the route,
`find_paths(to: "SampleApp.Orders.insert_order/1")` to get the hops between the two, and
then one `set_cards` with a card per hop — the route's action as the root, each callee
under its caller, a single card wherever two hops meet on the same function, and a
`highlight` on the call that writes the row. The browser redraws as the call lands, so the
reviewer watches the chain assemble instead of clicking it out.

## Ask the agent

Press ⌘I, or the `ask` button in the toolbar, for a chat panel over the canvas. Type what
you want to understand and the agent opens the cards that answer it.

The panel runs the [Claude Code](https://claude.com/claude-code) CLI headless, with the
indexed project's root as its working directory and Grasp as its only MCP server. Its
built-in tools are `Read`, `Grep` and `Glob`, so it reads the project's files and reaches
the index through Grasp's own tools, and it edits no file and runs no command. The
transcript shows each tool call as it happens; Stop kills the run, and New conversation
starts over.

The panel's Model select picks which model the CLI runs: the four aliases `haiku`,
`sonnet`, `opus` and `fable`, or `default` to leave the CLI on whatever `--agent-model` /
`GRASP_AGENT_MODEL` set, or on its own default when neither did. A pick takes effect on
the next prompt rather than interrupting a live run, and survives New conversation, so a
chain mapped out on an expensive model can be followed up on a cheap one.

One run at a time per session: a second prompt while one is in flight is refused rather
than queued. A follow-up continues the same CLI conversation, so the agent remembers what
it just opened. A single run is capped at 60 agent turns; one that reaches the cap stops
there and says so in the transcript. Transcripts live in memory and are gone when the
viewer stops.

The CLI has to be installed and signed in already — the panel runs whatever `claude` your
`PATH` resolves to. Two settings change that:

- `--agent-command PATH` or `GRASP_AGENT_COMMAND` — the executable to run instead of
  `claude`.
- `--agent-model NAME` or `GRASP_AGENT_MODEL` — the model that CLI runs with. Omit it to
  leave the CLI on its own default.

```
cd grasp && mix grasp.serve --index /path/to/project/.grasp/index.json \
  --agent-command /opt/homebrew/bin/claude --agent-model opus
```

## License

Apache-2.0.

The MCP endpoint is served by [Anubis MCP](https://hex.pm/packages/anubis_mcp), which is
LGPL-3.0. Grasp uses it as an unmodified dependency, resolved from Hex at build time.
