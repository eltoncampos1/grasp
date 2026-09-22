# grasp CLI

Visual, language-agnostic code review as a standalone CLI — a reimplementation of
[gfrancischelli/grasp](https://github.com/gfrancischelli/grasp) that is not a dependency of the
project under review. See [SPEC.md](SPEC.md) for the full design and roadmap.

**Status: v0.** `init`, `index` (TypeScript/JavaScript via tree-sitter), `pr` (worktree + fuzzy
picker), `doctor`, and `web` serving the canvas through upstream grasp's standalone viewer.

## Build

```bash
go build -o grasp .
# put it on PATH, e.g.:
cp grasp ~/.local/bin/
```

Requires Go 1.25+ and a C compiler (the tree-sitter grammars are compiled in via cgo).

## Quick start

```bash
cd any-repo
grasp init          # detect languages, base branch; pick a Claude profile; write .grasp/
grasp pr            # fuzzy-pick an open PR → worktree + index against its base
grasp web --no-index  # serve the canvas on the index the PR just wrote
```

Reviewing your own branch instead:

```bash
grasp web           # index the working tree against the base branch and serve
```

## Commands

| Command | What it does |
|---|---|
| `grasp init` | One-time repo setup: `.grasp/config.toml` (personal, gitignored), `.grasp/review.md` (committable team rules), `.gitignore` entries |
| `grasp pr [N]` | Open a PR in `.grasp/worktrees/pr-N` and index it against its base. No `N`: fuzzy picker over `gh pr list`. `--close` removes the worktree |
| `grasp index [--base REF]` | Write `.grasp/index.json` for the working tree (uncommitted and untracked work included) |
| `grasp web` | Index the current branch and serve the viewer (`--no-index` to serve the index already on disk, `--no-open` to keep the browser closed) |
| `grasp doctor [--ping]` | Show how everything resolves: repo, base, gh auth, agent binary + profile, index freshness |

## The v0 viewer

Until grasp-cli embeds a viewer of its own, `grasp web` serves the canvas through upstream
grasp's `mix grasp.viewer` (Elixir 1.19+):

```bash
git clone https://github.com/gfrancischelli/grasp ~/dev/grasp
cd ~/dev/grasp/grasp && mix deps.get && mix compile && mix esbuild.install
```

then in `.grasp/config.toml`:

```toml
[viewer]
grasp_checkout = "~/dev/grasp/grasp"
```

## Claude profiles

If you keep several Claude Code profiles (`CLAUDE_CONFIG_DIR`: `~/.claude`, `~/.claude-work`, …),
`grasp init` asks which one this repo's reviews should use and pins it in the config. Every agent
spawn sets that env explicitly, and `grasp doctor` prints the full resolution — no more guessing
which profile a tool landed on.

## v0 limitations

- Languages: TypeScript, TSX, JavaScript, JSX. More via tree-sitter grammars in v1.
- Call resolution is heuristic (same file → project-file imports → unique global name).
  Ambiguous or external calls are dropped rather than guessed.
- Functions inside `describe`/`it` callbacks and object-literal methods are not extracted.
- Entry points (routes, workers) are not detected yet.
- Auto-review on open and pluggable agents (Kimi, custom) are specced for v2 — see SPEC.md.
