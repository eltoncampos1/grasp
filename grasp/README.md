# Grasp

Call-chain code review for Elixir. Grasp draws each function as a card on a canvas: click a
call inside a card and the callee opens beside it, joined by an edge, so a call chain reads
left to right instead of as a series of editor jumps.

Indexed against a base branch the same canvas reviews a pull request — changed functions lead
the sidebar, a modified card swaps between its source and its diff, and review comments sit on
the lines they are about. A coding agent drives the canvas over MCP: it searches the index,
traces the paths into a function, lays the cards out, and answers the comments you left.

Grasp exists because agents now write more code than humans can comfortably review with a text
editor and a unified diff.

One Mix project and one Hex package: the indexer that writes a JSON call graph of a project,
the Phoenix LiveView canvas that renders it as branching function cards, and the MCP server an
agent drives it through.

## Requirements

- Elixir 1.19 or later
- Phoenix `~> 1.8` and Phoenix LiveView `~> 1.1` in the project you review
- `gh`, installed and signed in, to review pull requests
- the [Claude Code](https://claude.com/claude-code) CLI for the chat panel

## Install

Grasp mounts inside the application it reviews, the way LiveDashboard does. In that project's
`mix.exs`:

```elixir
{:grasp, git: "https://github.com/gfrancischelli/grasp.git", sparse: "grasp", only: :dev}
```

A Hex release will follow. Then, in the router:

```elixir
import Grasp.Router

scope "/" do
  pipe_through :browser
  grasp "/grasp"
end
```

and in the endpoint, beside the code reloader:

```elixir
if code_reloading? do
  plug Grasp.Plug, at: "/grasp"
end
```

The plug guards the mount — Grasp hands out your source and drives an agent that edits files,
so every request for it has to come from loopback — and serves the MCP endpoint at
`/grasp/mcp`. Its `at:` and the router's path must name the same mount.

In `.formatter.exs`:

```elixir
import_deps: [:grasp]
```

And in `.gitignore`:

```gitignore
.grasp/index.json
.grasp/worktrees/
```

## Quick start

```
mix grasp.index --base main
mix phx.server
```

Open <http://localhost:4000/grasp>, pick an entry point or a module in the sidebar or press
⌘K, and click any call inside a card to open the callee next to it. Register the MCP server
so an agent can drive the same canvas:

```
claude mcp add --transport http grasp http://localhost:4000/grasp/mcp
```

## Guides

- [Getting started](guides/getting-started.md) — install, the first index, the sidebar, the
  palette and the toolbar.
- [Reviewing](guides/reviewing.md) — the canvas, cards, edges, comments and sessions.
- [Pull requests](guides/pull-requests.md) — reviewing a branch or someone else's PR, and
  publishing the comments to GitHub.
- [The agent](guides/agent.md) — the chat panel, the MCP tools and what to ask for.
- [Indexing](guides/indexing.md) — what the index holds, how it stays current, and what it
  misses.
- [Contributing](guides/contributing.md) — layout, tests, assets and docs.

## License

Apache-2.0.

The MCP endpoint is served by [Anubis MCP](https://hex.pm/packages/anubis_mcp), which is
LGPL-3.0. Grasp uses it as an unmodified dependency, resolved from Hex at build time.
