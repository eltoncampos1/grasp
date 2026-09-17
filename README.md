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

Planned: sessions saved to disk, and guided tours the agent can author.

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
- The toolbar sits at the bottom centre of the canvas, and every control there names itself
  and its shortcut when you hover or tab to it. ⌘0 resets the canvas zoom, as does clicking
  the zoom percentage there. Some browsers also take ⌘0 for their own page zoom, and reset
  both.
- `fit` in the toolbar, or `f`, brings every card on the canvas into view at once.
- `signatures` in the toolbar, or `s`, turns the cards down to their signatures: the body
  goes, and the header and the syntax-highlighted line naming each function are scaled up so
  they stay readable however far out you are. The header's buttons keep working, so you can
  close or collapse a card without leaving the mode. Press it again for the code back.
- Ctrl+drag a frame's title to move the whole group: every card inside travels together and
  keeps its place relative to the others. Without Ctrl, clicking the title renames the group.
- A frame's title keeps its size at any zoom, so you can read which group is which from far
  enough out that the cards inside it are specks.
- ⌘M toggles the sidebar. On macOS the browser may take ⌘M for "minimise window", in
  which case use ⌘\\.
- A card's callers menu opens a caller to its left; open several and the card keeps one
  edge from each of them. A caller opened this way, or a callee opened by clicking a call,
  joins the group of the card it was opened from when it is new to the canvas, so it lands
  in the column beside that card inside the same frame.
- Click a line number to comment — hover it first for the `+` that marks it clickable.
  ⌘/Ctrl+Enter saves, Escape cancels; reply, resolve or reopen, delete on the thread. A
  resolved thread collapses to one line and expands on click. A thread whose line moved
  re-anchors wherever its text went; one that matches nowhere sits in the card's footer,
  outdated. The sidebar's Comments group lists every open thread under its module and jumps
  to the line when you click it.
- Arrow keys walk the graph, `x` closes the focused card, `Shift+x` closes it together
  with everything that had no other way to be reached, `c` collapses it, ⌘K opens the
  palette.
- **A group of cards is drawn as a frame** round the cards themselves, laid out from its own
  left edge, so two flows on one canvas are read apart rather than run together. The frame
  follows its cards: drag one to the edge of a flow and the frame grows with it, header and
  all, rather than leaving the card outside its own group. The frame's header
  carries its title, how many cards are in it, and `ungroup`, which takes the frame away and
  leaves the cards where they were. A title is a label rather than a requirement: a frame
  may stand with none. Cards in no group make a last, unframed section under the framed
  ones. An agent asked for several flows gives each one its own group over MCP, and you make
  and edit them by hand with the gestures below.
- Shift+click a card to pick it out; Shift+click it again to put it back. Selected cards wear
  a dashed outline. A plain click says which card you mean instead, so it lets the selection
  go — as do opening a card from the sidebar or the palette, and Escape. A card that closes
  leaves the selection with it, whether you closed it, another tab did, or an agent did. The
  selection is this tab's own: another tab reading the same session sees the frames you make,
  not the cards you are picking.
- ⌘G frames the selected cards, or the focused card when nothing is selected. The frame
  starts with no name. ⇧⌘G takes the selected cards back out of whatever frames they are
  in, leaving them selected, so they can go straight into another one.
- Click a frame's title to name or rename it in place — Enter saves, a blank name leaves the
  frame with none and its heading reading "Untitled group", Escape or clicking away leaves it
  as it was. The group keeps its id and its cards, so a tour or an agent holding that id
  still finds it. `ungroup` in the frame's header dissolves the whole frame.
- Drop a card anywhere inside another group's frame — on a card there, in the space between
  them, on the padding at its edge — to move it to that group; drag a selected card and the
  rest of the selection goes with it. Dropping it anywhere else — the unframed section, the
  bare canvas, its own frame — moves the card and nothing more. A card that changes group keeps
  the offset the drag gave it and so lands beside its place in the new frame rather than on
  it; "reset layout" puts every card back on the grid.

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
- **`changes only` folds the unchanged lines away**, the way a pull request shows a file:
  the changed lines, three lines of context on either side, every line a comment sits on,
  and one `⋯ n unchanged lines` row per stretch in between, which draws its lines when
  clicked. A function longer than 100 lines arrives folded; a shorter one arrives whole.
  `all lines` swaps back, and the `h` key does the same to the focused card.
- **A removed function opens as a card of its own**, tinted and showing the source the base
  had. Its `file:line` is the base commit's, so it is printed rather than linked into your
  editor.
- **A deleted line takes a comment too.** In the diff body, the line numbers on the base
  side are clickable the same way as any other; a thread left there sits under that line of
  the diff, on the code the branch removed.

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
- `get_function(id)` — one function's source, span, calls, callers, callees, the entry
  points that reach it, and the review comments still open on its lines.
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
  it, which is how several flows land on one canvas without running together. A card that
  names no group takes its parent's, so a hop added under a card that is already framed
  lands in the same frame without repeating the title. Nothing changes unless every card is
  good.
- `open_card(name, function_id, parent_card_id?, highlight?)` — add one card, called by
  another or standing on its own. A function already on screen gains an edge instead of a
  second card.
- `close_card(name, card_id)` — close one card and the edges touching it.
- `focus_card(name, card_id)` — scroll a card into view, to say "look here".
- `highlight_card(name, card_id, highlight)` — point at one call inside a card, or shade a
  range of its lines.
- `group_cards(name, title?, card_ids)` — frame cards already open, under `title` and
  joining the group already carrying it, or under a frame with no title when `title` is
  left out. A card belongs to one group, so naming it here takes it out of the one it was
  in, and a group left with no cards is gone.
- `ungroup_cards(name, card_ids)` — take cards out of their groups, back to the unframed
  section.
- `rename_group(name, group_id, title?)` — give a group another title, or none when `title`
  is left out, keeping its id and its cards. Regrouping under a new title would draw the
  same picture but build a different group, so a frame that outgrew its name is renamed
  rather than rebuilt.
- `set_view(name, card_id, view, context \\ nil)` — show a card as its `source` or as its
  `diff` against the base, to point at what the branch did to a function rather than at the
  function. Only a modified function has a diff; asking for one of anything else is an
  error. `context` says how much of that diff is drawn — `hunks` for the changed lines with
  three lines around them, `full` for every line, `auto` for hunks past 100 lines — and is
  left as it stands when omitted.

A session name defaults to `default`, which is the canvas at `/`; any other name is the
canvas at `/s/<name>` and is created on first mention.

Comments:

- `list_comments(function_id?, include_resolved?)` — the review comments written on the
  project's lines, the reviewer's and the agent's own, with their replies. Open threads
  only unless `include_resolved` is set. Each one says where it now sits: `anchored` on
  `anchored_line`, `outdated` when the line it was written on has been edited away, or
  `orphan` when the function has left the index.
- `add_comment(function_id, line, body, side?)` — write a comment on one line, as the
  agent, so a finding lands on the code it is about rather than in prose. `side` is `new`
  for the branch's code and `old` for the base version of a modified function, which is how
  a comment lands on a line the branch deleted.
- `reply_comment(comment_id, body)` — answer a thread, as the agent.
- `resolve_comment(comment_id, resolved?)` — close a thread once it is dealt with, or
  reopen one with `resolved: false`.

`get_function` carries a function's open threads under `comments`, so reading the code and
reading what the reviewer said about it is one call. Comments belong to the project, not to
a session: they are kept in `.grasp/comments.json` beside the index and show on whatever
canvas draws the function. The file travels with the checkout — commit it alongside the
changes it is about if you want the discussion to go with the PR, or add it to
`.gitignore` if you'd rather keep review chatter out of the repository.

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
indexed project's root as its working directory and Grasp as its only MCP server. In
`read-only` mode, the one it starts in, its built-in tools are `Read`, `Grep` and `Glob`,
so it reads the project's files and reaches the index through Grasp's own tools, and it
edits no file and runs no command. The transcript shows each tool call as it happens; Stop
kills the run, and New conversation starts over.

The panel's Mode select switches that. In `edit files` the agent also gets `Edit`, `Write`
and a `Bash` narrowed to seven commands: `mix`, `git status`, `git diff`, `git fetch`,
`git switch`, `gh pr view` and `gh pr checkout`. That lets it change files under the
project root — which is what makes "address all the comments and update the diagram
afterwards" a thing you can ask for. It works a comment at a time: reads what the
thread points at, makes the change, replies with what it did and resolves the thread; then
it runs `mix format` on what it touched, rebuilds the index with the same `mix grasp.index`
flags the viewer is watching — which needs `grasp_index` set up as a dev dependency of the
reviewed project, as in Quick start above, or there is no `mix grasp.index` task to run —
and lays the cards out again over the code as it now reads. The switch takes effect on the
next prompt, and survives New conversation. Nothing is sandboxed: edit mode is the agent
editing your working tree, so point it at a branch you can throw away and read the diff
before you keep it.

Edit mode also takes "Open PR 1212". The agent reads the pull request with `gh pr view` for
its base branch and title, runs `gh pr checkout`, fetches the base branch, rebuilds the
index against it with the same `--out` the viewer is watching, reloads the viewer and lays
the change out one group per flow. Uncommitted changes and untracked files ride along, as
they do on any `git switch`; a checkout git refuses because it would overwrite a modified
file stops the agent, which names the files rather than stashing or discarding anything. `gh` has to be installed and signed in, and the checkout
happens in your own working tree: the branch you had is gone from disk until you switch
back, so finish what you were doing first.

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
