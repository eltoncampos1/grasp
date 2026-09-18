# Contributing

How Grasp is laid out, how to run it against a project, and what the tests and the docs
expect.

## Repository layout

- `grasp/` — the package: the indexer (`mix grasp.index`, `Grasp.Index` and its submodules),
  the LiveView canvas (`GraspWeb.*`), the MCP server (`Grasp.MCP.*`) and the chat runner
  (`Grasp.Agent.*`). One Mix project, one Hex package.
- `grasp/guides/` — these pages.
- `docs/specs/` — the design record. `2026-09-15-grasp-design.md` describes the pipeline, the
  index JSON, the card graph, the MCP surface and the in-app mount, and is the place to read
  before changing any of them.
- `docs/plans/` — the implementation plans, milestone by milestone, kept as history.

## Working on Grasp itself

Grasp serves an endpoint of its own, run from this repository against any project's index:

```
cd grasp
mix setup
mix grasp.viewer --index /path/to/project/.grasp/index.json [--port 4040] [--editor vscode]
```

`mix setup` is `deps.get` plus `assets.build`. `config :grasp, standalone: true` is what gives
Grasp an endpoint; `mix grasp.viewer` sets it itself, and so does the test environment.
Mounted in a host application, Grasp starts no endpoint.

The standalone viewer pins its comments and sessions to the indexed project's root when that
is a directory on this machine, so a review written against someone else's code stays with
that code rather than with Grasp's checkout.

The first `mix deps.get` downloads Lumis' precompiled NIF, and the first cards rendered load
the tree-sitter grammars they need — Elixir, plus HTML, CSS and JavaScript for a `~H`
template. Both are one-off waits, seconds each, on a new machine.

## Tests

```
mix test       # unit tests
mix test.all   # unit tests plus the integration test
```

`mix test` excludes the `:integration` tag, so it needs no fixture deps and no subprocess
compile. `mix test.all` is `mix test --include integration`, and its integration test runs
`mix grasp.index` against the fixture application in a subprocess.

The fixture is a Mix project of its own at `test/fixtures/sample_app`, with phoenix,
phoenix_live_view and oban as dependencies (no database, nothing started): a router, some
controllers, LiveViews, workers and contexts for the indexer to read. The tests pin the line
and column of what it declares, so it is formatted on its own terms and is excluded from this
project's formatter inputs.

`test/fixtures/regenerate.exs` rewrites `test/fixtures/index.json`, the checked-in index the
unit tests read, from that fixture application. Run it after changing what the index holds.

## Assets

`priv/static/assets/grasp.js` and `grasp.css` are committed, because a host installs Grasp as
a dependency and never builds them: `GraspWeb.Assets` embeds both at compile time and serves
them under the mount path. The bundle carries Grasp's hooks and stylesheet alone — Phoenix,
`phoenix_html` and LiveView are read from the host's own `priv/static`, so the client always
matches the LiveView the host runs.

```
mix assets.build    # rebuild both files; commit them with the change that moved them
mix assets.deploy   # the same, minified
```

`mix assets.build` is what produces the committed files — unminified, with no sourcemap, so
the diff of a hook change is readable. The minified output and the dev server's inline
sourcemap do not belong in a commit.

The dev server runs esbuild in watch mode, and `@external_resource` on each file makes a
rebuild recompile the plug, so a saved hook reaches the browser on the next reload.

## Docs

```
mix docs
```

builds the HexDocs site from `README.md` and these guides. A guide links to another with a
plain relative path (`reviewing.md`), which works on GitHub and which ex_doc rewrites to the
generated page. `mix docs` must finish with no warnings about broken references.

## Writing rules

The two that come up in every review:

- **Comments state durable facts, never history.** A comment, a `@doc` or a `@moduledoc` is
  written for someone reading the code cold. It explains a constraint, an invariant or a
  non-obvious *why* — never what the code does, and never the change that introduced it.
  Phrases like "was overridden anyway", "as discussed", "changed to", "previously" or "now
  uses" belong in the commit message, not in the source.
- **Every module has a `@moduledoc`, and every public function a `@doc` and a `@spec`.** The
  moduledoc says what the module is and, where it is not obvious, the design decision behind
  it.

Run `mix format` before committing, and `mix compile --warnings-as-errors` and `mix test`
before opening a pull request.

## Issues

File bugs and feature requests at
<https://github.com/gfrancischelli/grasp/issues>. A bug report is most useful with the Elixir
and Phoenix versions, what `mix grasp.index` printed, and — for a wrong or missing edge — the
two functions involved and how the call is written.
