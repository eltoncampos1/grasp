# grasp

The viewer half of [Grasp](../README.md): a Phoenix LiveView app that renders a Grasp
index as a branching tree of function cards.

```
cd grasp
mix setup
mix grasp.serve --index /path/to/project/.grasp/index.json [--port 4040] [--editor vscode]
```

Open http://127.0.0.1:4040. Cmd+K (Ctrl+K) opens the function palette. Clicking a call
inside a card opens the callee as a child card; a card's callers menu opens the other way
up the chain. Arrow keys move focus between cards, `x` closes the focused card and `c`
collapses it.

Diffs, entry points, sessions saved to disk and the MCP server are not built yet.

## Tests

```
mix test
```
