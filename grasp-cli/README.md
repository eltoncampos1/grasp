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

The canvas is a whiteboard: cards stay where you put them, and a review **arrives already laid
out** — every changed function opens as a card, one column per module, modified cards showing
their diff, with edges drawn where one changed function calls another.

- **Drag a card by its header** (or Ctrl+drag from anywhere on it); drag the background to pan,
  hold Space to pan from anywhere; `⌘`+wheel zooms about the cursor, the wheel alone pans.
  `reset layout` re-stacks everything by call depth. Arrow keys walk the graph from the focused
  card. `s` turns every card down to its signature for a far-out view.
- **Click a call inside a card** and the callee opens to its right; the **callers menu** opens a
  caller to its left — each joined by a colored edge from the exact call site. Double-click an
  edge to jump to the card at its far end. Syntax highlighting for Elixir, JS/TS and Go.
- **`d` toggles diff/source** on the focused card; **`h` folds unchanged lines** into
  `⋯ n unchanged lines` expanders (a >100-line diff arrives folded; comment lines stay drawn);
  **`c` collapses to the header; `x` closes; `Shift+x` closes the whole subtree** nothing else
  reaches.
- **Click a line number to comment**; Shift+click another number stretches the thread over a
  range (tinted). Works on the base side of a diff too. Threads persist in
  `.grasp/comments.json` under the main checkout — they survive `grasp pr --close` — and the
  sidebar's Comments group lists the open ones. Reply, resolve, delete inline.
- **The sidebar is review-first**: Changes, open Comments, then Related — only the modules one
  call away from the change. The full module list stays behind a toggle; `⌘K` searches
  everything.
- **Sessions** keep the whole arrangement — cards, positions, views, pan and zoom — in
  `.grasp/sessions/<name>.json`, autosaved a moment after the canvas changes. A PR review names
  its session `pr-N` automatically; the header menu switches, creates and deletes sessions, and
  `?s=<name>` addresses one directly.
- **Live reload**: rewrite the index (`grasp index`, `grasp pr`) and the canvas redraws in about
  a second, keeping your session. The server answers loopback requests only (Host-checked,
  DNS-rebinding safe).

## The agent (`⌘I`)

The `ask` panel runs the configured agent CLI headless — Claude Code by default, under the
profile pinned at `grasp init` — with the reviewed tree (the PR's worktree, when reviewing one)
as its working directory, primed with the review's changed functions and `.grasp/review.md`.

- **read-only mode** gives it `Read`, `Grep`, `Glob` — it reads code and answers, edits nothing.
- **edit files mode** adds `Edit`, `Write` and a Bash narrowed to `mix`/`go`/`git status`/
  `git diff`/`git fetch`/`gh pr view` — nothing that changes the checked-out branch.
- Model select (default/haiku/sonnet/opus/fable), one run at a time, 60-turn cap, Stop kills
  the run, follow-ups resume the same conversation per session, `new` starts over.

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

MCP server so the agent can drive the canvas itself (open/arrange cards, answer threads) ·
groups/frames on the canvas · comment re-anchoring when lines move · drag-to-select comment
ranges · auto-review on open fed by `.grasp/review.md` (`--no-review` to skip) · pluggable
agent backends (Kimi, custom) · entry-point detectors · `web --watch`.
