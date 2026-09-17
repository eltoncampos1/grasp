# grasp

The viewer half of [Grasp](../README.md): a Phoenix LiveView app that renders a Grasp
index as a branching tree of function cards.

```
cd grasp
mix setup
mix grasp.viewer --index /path/to/project/.grasp/index.json [--port 4040] [--editor vscode]
```

From the project under review, `mix grasp.serve` — the launcher in `grasp_index` — finds a
checkout of this repository and runs the same task inside it.

The first `mix deps.get` downloads Lumis' precompiled NIF, and the first cards rendered
load the tree-sitter grammars they need — Elixir, plus HTML, CSS and JavaScript for a
`~H` template. Both are one-off waits, seconds each, on a new machine.

Open http://127.0.0.1:4040. The sidebar lists the project's entry points in collapsible
groups — Routes, Background jobs, Live views, Processes, Supervision, Plugs, Other — and
then Modules, and a group with nothing in it is not shown. The routes open on arrival
while there are at most fifty of them; a project with no entry points at all opens the
module list instead. Routes are bucketed by the router that declared them and listed by
`VERB /path`, in path order; the other groups bucket their callbacks under a module
heading and print each as `fun/arity`. Clicking any row opens that function as a new root card, and a card
whose function is an entry point wears a badge saying which. Cmd+K (Ctrl+K) opens the
function palette. Clicking a call inside a card opens the callee as a child card; a
card's callers menu opens the other way up the chain. Arrow keys move focus between
cards, `x` closes the focused card and `c` collapses it.

The cards sit on a canvas that pans and zooms, and a card can be dragged out of its
automatic position by its header; the toolbar along the top holds the sidebar toggle,
zoom out, the zoom readout, fit, zoom in, and "reset layout", which puts every card back
where the tree would have placed it. The full set of pointer and key gestures is listed
under [Gestures](../README.md#gestures).

Diffs, sessions saved to disk and the MCP server are not built yet.

## Tests

```
mix test
```
