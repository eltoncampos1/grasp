# Grasp

Call-chain code review for Elixir.

Grasp renders a function as a card. Click any call inside it and the callee opens as a
child card to the right, so a deep call chain reads left to right instead of as a series
of editor jumps. Cards can show the function's diff against a base branch, the top level
lists the codebase's entry points (Phoenix routes, Oban workers, LiveViews, OTP
callbacks), and Cmd+K finds any function. An MCP server lets coding agents arrange the
cards, annotate them and author guided tours for the human reviewer.

Grasp exists because agents now write more code than humans can comfortably review with
a text editor and a unified diff.

## Layout

- `grasp_index/` — the indexer. Added to a target project as a dev dependency;
  `mix grasp.index` writes a JSON index of every function, its resolved calls, and the
  project's entry points.
- `grasp/` — the viewer. A Phoenix LiveView app that serves the index as a card canvas
  and exposes an MCP server for coding agents.

See `docs/specs/2026-09-15-grasp-design.md` for the design.

## License

Apache-2.0.
