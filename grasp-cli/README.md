# grasp CLI

Visual, language-agnostic code review as a standalone CLI. A single Go binary indexes a repo's
functions and call sites with tree-sitter, reviews branches and pull requests in worktrees, and
serves its own review canvas — no dependency added to the project under review, no other runtime
needed. Inspired by [gfrancischelli/grasp](https://github.com/gfrancischelli/grasp), fully
independent of it. See [SPEC.md](SPEC.md) for the design and roadmap.

**Languages:** Elixir, JavaScript/TypeScript (JSX/TSX included), Go. The index format is
language-neutral; more languages are a tree-sitter grammar plus an extractor away.

## Build

```bash
go build -o grasp .
cp grasp ~/.local/bin/   # or anywhere on PATH
```

Requires Go 1.25+ and a C compiler (the tree-sitter grammars compile in via cgo).

## Quick start

```bash
cd any-repo
grasp init            # detect languages, base branch; pick a Claude profile; write .grasp/
grasp pr              # fuzzy-pick an open PR → worktree + index against its base
grasp web --no-index  # serve the canvas on the index the PR wrote, open the browser
```

Reviewing your own branch:

```bash
grasp web             # index the working tree against the base branch and serve
```

## Commands

| Command | What it does |
|---|---|
| `grasp init` | One-time repo setup: `.grasp/config.toml` (personal, gitignored), `.grasp/review.md` (committable team rules), `.gitignore` entries |
| `grasp pr [N]` | Open a PR in `.grasp/worktrees/pr-N` and index it against its base. No `N`: fuzzy picker over `gh pr list`. `--close` removes the worktree |
| `grasp index [--base REF]` | Write `.grasp/index.json` for the working tree (uncommitted and untracked work included) |
| `grasp web` | Serve the embedded review canvas on 127.0.0.1 (`--no-index` to serve the index already on disk, `--no-open`, `--port`) |
| `grasp publish [N]` | Send local comment threads to the PR as review comments via `gh`. Already-published threads are skipped |
| `grasp doctor [--ping]` | Show how everything resolves: repo, base, gh auth, agent binary + profile, index freshness |

## The canvas

- **Changes lead the sidebar**, grouped by module with added/modified/removed badges; the full
  module list and a filter sit under them. `⌘K` opens a fuzzy palette over every function.
- **Click a call inside a card** and the callee opens beside it, joined by an edge — a call
  chain reads left to right instead of as editor jumps.
- **`d` toggles a modified card** between source and diff (computed against the base version);
  **`h` folds unchanged lines** into `⋯ n unchanged lines` expanders.
- **Click a line number to start a comment thread** — on the new side, or the base side of a
  diff. Threads persist in `.grasp/comments.json` under the main checkout, so they survive
  `grasp pr --close`. Reply, resolve, delete inline.
- **A removed function opens as a card of its own**, tinted, showing the base's source.
- **Live reload**: rewrite the index (`grasp index`, `grasp pr`) and the canvas redraws in about
  a second, keeping the cards you had open. `file:line` deep-links into vscode/cursor/zed/idea
  when `web.editor` is set.
- The server answers loopback requests only (Host-checked, DNS-rebinding safe).

## Claude profiles

If you keep several Claude Code profiles (`CLAUDE_CONFIG_DIR`: `~/.claude`, `~/.claude-work`, …),
`grasp init` asks which one this repo's reviews should use and pins it in the config. Every agent
spawn sets that env explicitly, and `grasp doctor` prints the full resolution.

## Indexing notes and limitations

- Call resolution is syntactic, per language:
  - **Elixir**: def/defp/defmacro clauses merged per name/arity; remote calls through aliases
    (`alias Foo.{Bar}`, `as:`), `__MODULE__`, imports (`only:` respected), captures `&fun/2`;
    pipe arity (+1) tried on lookup. No macro expansion — what `use` injects stays invisible.
  - **JS/TS**: same-file names, project-relative imports (default/named/namespace), unique
    project-wide names; JSX component tags are call sites; `forwardRef`/`memo`-style wrappers
    unwrapped. Path aliases (`@/`) not resolved yet.
  - **Go**: package-level calls across a directory's files, `pkg.Fn` through imports inside this
    module (via go.mod). Method calls on variables need type info and are skipped.
- Ambiguous or external calls are dropped rather than guessed.
- Entry points (routes, workers) are not detected yet.

## Roadmap (SPEC.md has the detail)

MCP server so an agent can drive the canvas · chat panel spawning the configured agent
(Claude profile-pinned; Kimi/custom backends) · auto-review on open fed by `.grasp/review.md`
(`--no-review` to skip) · saved sessions · entry-point detectors.
