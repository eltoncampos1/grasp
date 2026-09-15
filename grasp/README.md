# grasp

The viewer half of [Grasp](../README.md): a Phoenix LiveView app that renders a Grasp
index as a branching tree of function cards.

```
cd grasp
mix setup
mix grasp.serve --index /path/to/project/.grasp/index.json [--port 4040] [--editor vscode]
```

Open http://127.0.0.1:4040. Cmd+K (Ctrl+K) opens the function palette. Clicking a call
inside a card opens the callee as a child card.

## Tests

```
mix test
```
