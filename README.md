# Grasp

Call-chain code review for Elixir.

Grasp renders a function as a card. Click any call inside it and the callee opens as a
child card to the right, so a deep call chain reads left to right instead of as a series
of editor jumps. A sidebar lists the project's modules and their functions, a card's
callers menu opens the other way up the chain, Cmd+K finds any function, and every card
links its `file:line` into your editor.

Planned: the function's diff against a base branch on the card, a top level listing the
codebase's entry points (Phoenix routes, Oban workers, LiveViews, OTP callbacks),
sessions saved to disk, and an MCP server letting coding agents arrange the cards,
annotate them and author guided tours for the human reviewer.

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

Open http://127.0.0.1:4040, pick a module in the sidebar or press ⌘K, and click any call
inside a card to open the callee next to it.

## Gestures

- Drag a card by its header to move it, or hold Ctrl and drag from anywhere on it. Ctrl
  and press over a card is the drag gesture, so the context menu is suppressed there;
  a plain right-click still opens it.
- Drag the background to pan; hold Space to pan from anywhere, cards included.
- ⌘ or Ctrl with the wheel zooms about the cursor; the wheel alone pans, except over
  something that can scroll itself.
- ⌘0 resets the canvas zoom, as does clicking the zoom percentage in the toolbar. Some
  browsers also take ⌘0 for their own page zoom, and reset both.
- ⌘M toggles the sidebar. On macOS the browser may take ⌘M for "minimise window", in
  which case use ⌘\\.
- Arrow keys walk the tree, `x` closes the focused card, `c` collapses it, ⌘K opens the
  palette.

## License

Apache-2.0.
