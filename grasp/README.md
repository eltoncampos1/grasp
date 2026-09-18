# grasp

Call-chain code review for Elixir, mounted in your app. One package: the indexer that
writes a JSON call graph of a project, the Phoenix LiveView canvas that renders it as
branching function cards, and the MCP server an agent drives it through. The repository
root's [README](../README.md) describes the canvas and its gestures.

Add it to the project you want to review:

```elixir
{:grasp, "~> 0.1", only: :dev}
```

## Indexing

```
mix grasp.index [--out .grasp/index.json] [--base main] [--build-path _build/grasp]
```

The task forces a full recompile with a compiler tracer attached, so every call the
compiler resolves is recorded with the position of the call in your source, then joins
those calls with the function definitions Sourceror finds and writes one JSON document.
The canvas and the MCP server read that document; `Grasp.Index` is the reader they use.

The first index is a full build, and that is the only one you have to ask for. Once Grasp
is running in your dev server it installs the same tracer into the VM's compiler options,
so every compile your code reloader performs after a save reports its calls too: a third of
a second after the last one, Grasp re-extracts the files the compile touched, rebuilds
their records, rewrites the index and the canvas follows. Run `mix grasp.index` again when
something outside a save changes — a branch switch, a new `--base`, a dependency.

The forced recompile happens in a build directory of Grasp's own, `_build/grasp`, seeded by
copying the project's current build the first time it is missing, so it neither waits on
the dev server's build lock nor invalidates the beams the server is running. `--build-path`
names another one; naming the project's own runs the build in place.

`--base REF` classifies every function against the merge base of `REF` and `HEAD` — added,
modified, unchanged or removed — and carries the base version of each modified function's
source, which is what turns the canvas into a pull-request review.

The document also lists the project's **entry points** — the places its code starts
executing. After compiling, the task loads the application's modules and reads what they
export and what behaviours they declare: Phoenix routers (by their `__routes__/0`) give a
`route` per controller action and a `live_route` per LiveView route, with the verb, path,
router and helper as meta, and a router mounted with `forward` has the mount's prefix on
its paths; `Oban.Worker` gives `perform/1` with its queue and max attempts;
`Phoenix.LiveView`, `Phoenix.LiveComponent`, `GenServer`, `Supervisor`, `Application` and
`Plug` give the callbacks their behaviour declares, minus the few that configure a module
rather than run its work. A callback is listed only when the index holds a definition for
it, so the defaults `use GenServer` injects and a dependency's forwarded controllers stay
out. Each module record also carries the `behaviours` it declares.

The document shape is described in `docs/specs/2026-09-15-grasp-design.md` at the repo
root under "Index JSON".

## Serving

Grasp mounts in the host application's router, with `Grasp.Plug` in the host's own endpoint
guarding that mount and serving the MCP endpoint, and runs on the host's dev server; see the
root README's Quick start. It starts no endpoint of its own there;
`config :grasp, standalone: true` is what gives it one, and `mix grasp.viewer` sets that
itself.

```
cd grasp
mix setup
mix grasp.viewer --index /path/to/project/.grasp/index.json [--port 4040] [--editor vscode]
```

That is how Grasp is worked on, and how any index is opened without touching the project
it describes.

The first `mix deps.get` downloads Lumis' precompiled NIF, and the first cards rendered
load the tree-sitter grammars they need — Elixir, plus HTML, CSS and JavaScript for a
`~H` template. Both are one-off waits, seconds each, on a new machine.

A project that has never run `mix grasp.index` opens on a page saying so and naming the
task; the store watches the path all the same and the canvas fills in as soon as the file
is written.

## Assets

`priv/static/assets/grasp.js` and `grasp.css` are committed, because a host installs Grasp
from Hex and never builds them: `GraspWeb.Assets` embeds both at compile time and serves
them under the mount path. The bundle carries Grasp's hooks and stylesheet alone — Phoenix,
`phoenix_html` and LiveView are read from the host's own `priv/static`, so the client always
matches the LiveView the host runs.

`mix assets.build` is what produces the committed files — unminified, with no sourcemap, so
the diff of a hook change is readable. `mix assets.deploy` minifies, and the dev server's
watcher adds an inline sourcemap; neither output belongs in a commit.

```
mix assets.build    # rebuild both files; commit them with the change that moved them
mix assets.deploy   # the same, minified
```

The dev server runs esbuild in watch mode, and `@external_resource` on each file makes a
rebuild recompile the plug, so a saved hook reaches the browser on the next reload.

## Tests

```
mix test       # unit tests
mix test.all   # unit tests plus the integration test, which runs mix grasp.index
               # against test/fixtures/sample_app in a subprocess
```

`mix test` excludes the `:integration` tag, so it needs no fixture deps and no subprocess
compile. `mix test.all` is `mix test --include integration`.
