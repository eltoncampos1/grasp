# Grasp In-App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grasp becomes one development dependency mounted inside the reviewed application's endpoint, the way Tidewave and LiveDashboard are: `{:grasp, only: :dev}`, `grasp "/grasp"` in the router, review at `localhost:4000/grasp`. Its compiler tracer rides the host's code reloader so cards follow a save without a rebuild, and pull requests are reviewed from worktrees so the host never switches its own tree.

**Architecture:** `grasp_index/` folds into `grasp/` (one Mix project, app `:grasp`, modules unchanged). `Grasp.Application` starts the core supervisor whenever Mix is running and the endpoint only when `standalone: true`. `Grasp.Router.grasp/2` mounts a `live_session`, the MCP forward and an assets plug that embeds the host's own Phoenix/LiveView JavaScript plus Grasp's hooks bundle. `Grasp.Reindexer` installs the tracer in the VM and updates the index incrementally from the events the code reloader's compiles produce, through a `Grasp.Index.Builder` refactored into composable steps. `mix grasp.pr N` does the worktree recipe; `mix grasp.index` builds in `_build/grasp`.

**Tech Stack:** Elixir / Phoenix 1.8 / LiveView `~> 1.1` / anubis_mcp / Lumis 0.8 / Sourceror / esbuild.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 4 (In-app Grasp), which overrides Parts 1–3 where they differ.

## Global Constraints

- Public repo: names within SampleApp/acme; `@moduledoc`/`@doc`/`@spec` on everything public; HEEx `attr`; comments state durable facts, never history. Never `git add -A` (ExUnit tmp dirs under `grasp/tmp/`); add by path; use `git mv` for moves. Trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Gates (single project `grasp/` after Task 1): `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test --include integration` (the integration test compiles `test/fixtures/sample_app`). Tests never run the real `gh`/`claude` or the network; `git` runs only in the pre-existing base-ref tests and the new worktree tests against temporary repositories.
- LiveView requirement is `~> 1.1` (the suite passes on 1.1.33 and 1.2.11 — verified); do not use a 1.2-only API.

---

### Task 1: One package

**Files:** move `grasp_index/lib/**` → `grasp/lib/**` (`Grasp.Index.*`, `Mix.Tasks.Grasp.Index`; delete `grasp_index/lib/grasp/index/viewer.ex` and `grasp_index/lib/mix/tasks/grasp.serve.ex` — the launcher goes away), `grasp_index/test/**` → `grasp/test/**` (fixtures `grasp_index/test/fixtures/sample_app` → `grasp/test/fixtures/sample_app`, adjusting `test_load_filters`/`test_ignore_filters` and the integration test's paths), `grasp_index/README.md` content folded into `grasp/README.md`/root README; delete `grasp_index/` entirely; modify `grasp/mix.exs` (deps, package metadata, `elixirc_paths`, aliases incl. `test.all`, `listeners`), `grasp/lib/grasp/application.ex`, `grasp/config/*.exs`, `grasp/lib/mix/tasks/grasp.viewer.ex`, `.github` if a CI file exists, root `README.md`.

**Interfaces (produced):**

```elixir
# mix.exs: app :grasp, version 0.1.0, deps:
#   {:phoenix, "~> 1.8"}, {:phoenix_html, "~> 4.3"}, {:phoenix_live_view, "~> 1.1"},
#   {:bandit, "~> 1.12", optional: true}, {:jason, "~> 1.4"}, {:lumis, "~> 0.8"},
#   {:lazy_html, ">= 0.1.0"}, {:anubis_mcp, "~> 2.0"}, {:sourceror, "~> 1.0"} (the version grasp_index used),
#   {:esbuild, "~> 0.10", only: :dev, runtime: false}
#   package/0 and description from grasp_index's mix.exs, adapted ("Grasp: call-chain code review for Elixir, mounted in your app").
# Grasp.Application.start/2:
#   core = [PubSub, IndexStore, Comments, SessionRegistry, SessionSupervisor, AgentRegistry, AgentSupervisor, MCP.Server]
#   children = if mix_running?(), do: core ++ endpoint_if_standalone(), else: []   (log a warning when Mix is absent, as Tidewave does)
#   standalone? = Application.get_env(:grasp, :standalone, false)
# config/config.exs: standalone: false; config/dev.exs (grasp's own): standalone: true; config/test.exs: standalone: true.
# Mix.Tasks.Grasp.Viewer sets Application.put_env(:grasp, :standalone, true) before `run --no-halt` (it already sets GRASP_* env; keep them).
```

**Requirements:**

- Everything under `Grasp.Index.*` moves unchanged in name; `Grasp.Index.Builder`, `BaseRef`, `Changes`, `Entry_points`, `Extract`, `Heex`, `Join`, `Templates`, `Tracer` keep their tests. `Mix.Tasks.Grasp.Index` moves; `Mix.Tasks.Grasp.Serve` and `Grasp.Index.Viewer` are deleted with their tests. `grasp/test/fixtures/regenerate.exs` updates its path to the sample app.
- `config :grasp, index_path:` default becomes `Path.join(File.cwd!(), ".grasp/index.json")` resolved at IndexStore start when unset, and a missing file is not an error: the store starts empty, `GraspWeb.ReviewLive` shows "No index at PATH — run `mix grasp.index`" in its empty state (there is an empty state already; adjust its text), and the poll picks the file up when it appears.
- The root README's Quick start becomes the in-app install (dep line, `mix deps.get`, router lines — the macro arrives in Task 2, so write the README lines now and mark nothing as pending —, `mix grasp.index --base main`, `mix phx.server`, open `/grasp`); a "Working on Grasp itself" section keeps `cd grasp && mix setup && mix grasp.viewer --index …`. The launcher paragraphs go.
- Tests: the whole merged suite green (`mix test --include integration`); a test that `Grasp.Application` children include the endpoint only under `standalone: true` (assert on `Supervisor.which_children(Grasp.Supervisor)` in the test env, which is standalone; and a unit test of the children-list function with `standalone: false`).
- Gates; commit `Grasp is one package`.

---

### Task 2: Mounted in the host

**Files:** create `grasp/lib/grasp/router.ex` (`Grasp.Router`, `defmacro grasp/2`), `grasp/lib/grasp_web/plugs/assets.ex` (`GraspWeb.Assets`), `grasp/test/grasp_web/router_test.exs`; modify `grasp/lib/grasp_web/router.ex` (use the macro at `/`), `grasp/lib/grasp_web/components/layouts.ex` + `layouts/root.html.heex` (asset URLs, live socket path), `grasp/assets/js/app.js` (globals instead of imports), `grasp/config/config.exs` (esbuild args: `--external:phoenix --external:phoenix_html --external:phoenix_live_view`, output `priv/static/assets/grasp.js` + `grasp.css`), `grasp/lib/grasp_web/endpoint.ex` (Plug.Static no longer needed for the bundle), README (router lines verified), spec if a detail differs.

**Interfaces (produced):**

```elixir
# Grasp.Router
defmacro grasp(path, opts \\ [])
#   opts: live_session_name (default :grasp), on_mount (list, default []).
#   Expands to:
#     scope path, alias: false, as: false do
#       import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]
#       live_session name, root_layout: {GraspWeb.Layouts, :root}, layout: false, on_mount: on_mount do
#         live "/", GraspWeb.ReviewLive, :index, private: %{grasp_path: path}
#         live "/s/:name", GraspWeb.ReviewLive, :session, private: %{grasp_path: path}
#       end
#       get "/assets/:asset", GraspWeb.Assets, :asset      # via a plug pipeline-free forward or Plug route
#       forward "/mcp", GraspWeb.Plugs.LocalOnlyMcp, server: Grasp.MCP.Server   # LocalOnly then the anubis plug
#     end
#   The LiveView reads the mount path from the route's private (or from the request path) so links
#   (`/s/:name`, `default` → `path`) and the assets/live socket URLs are built under `path`.

# GraspWeb.Assets (Plug)
#   At compile time: phoenix_js = File.read!(Application.app_dir(:phoenix, "priv/static/phoenix.js")),
#   live_view_js = File.read!(Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")),
#   grasp_js = File.read!("priv/static/assets/grasp.js"), grasp_css = File.read!("priv/static/assets/grasp.css")
#   (@external_resource on each). Serves "grasp.js" (phoenix_js <> "\n" <> live_view_js <> "\n" <> grasp_js) and "grasp.css"
#   with content-type, `cache-control: public, max-age=31536000, immutable` when the request carries `?vsn=<hash>` matching,
#   else no-cache; 404 for other names. GraspWeb.Layouts.asset_path(conn_or_socket, :js | :css) builds "<path>/assets/grasp.js?vsn=<hash>".
#   The root layout's <script> uses `defer` and `app.js` reads `window.Phoenix` and `window.LiveView` (the two priv files define them).
#   The LiveSocket path: Phoenix.Endpoint's `:live_socket_path`? LiveView exposes it via `Phoenix.LiveView.Router`/endpoint config —
#   read how phoenix_live_dashboard's `LayoutView.live_socket_path/1` does it (deps/phoenix_live_dashboard in any host, or hexdocs) and do the same.
```

**Requirements:**

- The standalone `GraspWeb.Router` becomes: browser pipeline (session, LocalOnly, csrf) + `scope "/" do pipe_through :browser; grasp "/" end`, so every existing LiveView test runs through the macro. Assert in `router_test.exs` that a second router module in test support mounting `grasp "/tools/grasp"` produces routes `/tools/grasp`, `/tools/grasp/s/:name`, `/tools/grasp/assets/:asset`, `/tools/grasp/mcp` (inspect `Phoenix.Router.routes/1`), and that the LiveView under the prefix links to `/tools/grasp/s/foo` (mount it through a test endpoint or assert on the LiveView's computed path helper).
- `GraspWeb.Assets` test: `GET /assets/grasp.js` in the standalone app returns 200 with `application/javascript`, body starting with the Phoenix JS and containing `LiveSocket`; `grasp.css` returns `text/css`; unknown → 404; the `vsn` match sets the immutable cache header.
- `mix assets.build` output is committed? Decide: the package must ship built assets for hosts (`priv/static/assets/grasp.js|css` committed, as LiveDashboard commits `dist/`), so remove `priv/static/assets` from `.gitignore` if present and commit the built files; `mix assets.build` regenerates them (developer step, documented).
- The chat panel, palette and keys hooks keep working under a prefix (they push events, no URLs); the MCP `LocalOnly` plug wraps the forward.
- README: the install snippet (dep, `import Grasp.Router`, `grasp "/grasp"` inside the browser scope, dev config keys), "Registering the MCP server: `claude mcp add --transport http grasp http://localhost:4000/grasp/mcp`".
- Gates; commit `Grasp mounts in the host's router`.

---

### Task 3: The tracer rides the code reloader

**Files:** modify `grasp/lib/grasp/index/builder.ex` (split into steps), create `grasp/lib/grasp/index/incremental.ex`, `grasp/lib/grasp/reindexer.ex`, tests `incremental_test.exs`, `reindexer_test.exs`; modify `grasp/lib/grasp/application.ex` (start `Grasp.Reindexer` when Mix is running and not standalone — in standalone mode there is no host compile to watch), `grasp/lib/grasp/index/tracer.ex` (events carry `env.file` already; make `start/0` idempotent and add `take_events/0` that drains), `grasp/lib/mix/tasks/grasp.index.ex` (`--build-path`, default `_build/grasp`, seeded from `_build/<Mix.env()>` by copying when missing; `MIX_BUILD_PATH` set for the forced compile — check how `Mix.Project.build_path/0` reads it and whether a running task can switch build paths; if not, run the compile in a `System.cmd("mix", ["compile", "--force"], env: [{"MIX_BUILD_PATH", …}])` subprocess with the tracer installed via `-r`/`--erl`? — simplest robust route: the task re-execs `mix grasp.index --in-build-path` as a subprocess with `MIX_BUILD_PATH` set, and only the child traces; say which you did), README §Indexing, spec Part 4 if details differ.

**Interfaces (produced):**

```elixir
# Grasp.Index.Builder steps (public, each documented):
@spec extract(root, [relative_file]) :: %{definitions: [...], modules: [...], embeds: [...]}
@spec join(definitions, events) :: [record]           # existing Join.join/2
@spec entry_points(app) :: [entry_point]
@spec classify(records, base_ctx) :: [record]         # change/base_source/removed per record
@spec document(records, modules, entry_points, project, git) :: map()   # the JSON document (string keys)
# run/1 composes them as today.

# Grasp.Index.Incremental
@spec update(document :: map(), root :: Path.t(), changed_files :: [relative_file], events :: [Tracer.event()], base_ctx) :: {:ok, map()} | {:error, term()}
#   Removes the records whose "file" is in changed_files (and their modules), extracts the files that still exist,
#   joins the given events for those definitions (events for other files are ignored), recomputes entry points from
#   loaded modules, classifies the new records against base_ctx (base sources via git show, memoised per file in
#   base_ctx), and returns the merged document. Records of other files are untouched. Template records whose
#   embedding module's file changed are rebuilt too (their embeds come from that file).

# Grasp.Reindexer (GenServer)
#   start_link(opts) — installs the tracer: Code.put_compiler_option(:tracers, [Grasp.Index.Tracer | current]) and
#   parser_options columns: true (idempotent); subscribes to nothing; receives {:events, n} notifications from the tracer
#   (Tracer.trace/2 sends a message to the reindexer when registered) and schedules :flush 300 ms after the last one;
#   on :flush: takes the events, keeps those whose file is under the project's elixirc paths, groups by file, loads the
#   current index document (from the store's path), runs Incremental.update/5 with the base ref recorded in the
#   document's "git.base_ref" (nil → no classification, change "unchanged"), writes the document to the index path
#   (atomic rename) and calls IndexStore.reload/0. Errors are logged, never crash the host.
#   @spec flush_ms() :: 300
```

**Requirements:**

- The tracer must not slow the host's compile noticeably: `trace/2` does an ETS insert and, at most once per 300 ms window, a `send` to the reindexer.
- Entry points from loaded modules: `Grasp.Index.EntryPoints` today runs inside `mix grasp.index` after `loadpaths`; in the reindexer the modules are already loaded in the VM — verify `EntryPoints` works from a running app (`:application.get_key(app, :modules)` plus `Code.ensure_loaded?`), and that the app name comes from `Mix.Project.config()[:app]`.
- `incremental_test.exs`: build a document from the sample app fixture index (the committed `test/fixtures/index.json` is fine), then call `update/5` with a changed copy of `lib/sample_app/greeter.ex` under a `tmp_dir` root (write the file with one more function and one renamed call) and synthetic events for it → the returned document has the new function, the renamed call, no stale record, other records byte-identical, modules updated. Base classification with `base_ctx: nil` → "unchanged".
- `reindexer_test.exs` (`async: false`): start a reindexer pointed at a tmp index path with a copy of the fixture document and root; compile a module with `Code.compile_string/2` whose `file` is a path under the tmp root's `lib/` mirroring the fixture module (the tracer sees it) → within 1 s the index file is rewritten and `IndexStore` (a test-scoped store, or the app store re-pointed and restored) holds the new record. Because the tracer is global to the VM, this test module owns it: install, run, and `Code.put_compiler_option(:tracers, previous)` in `on_exit`.
- `mix grasp.index --build-path`: integration test asserts the fixture build lands under `_build/grasp` (or the chosen path) and that `_build/dev` of the fixture app is untouched (mtime of a beam unchanged).
- README §Indexing: the first index is a full build; afterwards saves update the canvas; `--build-path`.
- Gates; commit `The tracer rides the code reloader`.

---

### Task 4: Pull requests from worktrees

**Files:** create `grasp/lib/mix/tasks/grasp.pr.ex`, `grasp/lib/grasp/pull_request.ex` (the recipe as functions with an injected command runner, like `Grasp.Index.Viewer` had), tests `pull_request_test.exs` (temporary git repositories, a fake `gh` script — reuse the shape of `test/support/fake_gh.sh`, extending it with `pr view N --json baseRefName,headRefName,title,url`); modify `grasp/lib/grasp/agent/command.ex` (recipe + allowlist), `grasp/lib/grasp/comments.ex` and `grasp/lib/grasp/session/disk.ex` (home directory = `Application.get_env(:grasp, :home)` defaulting to the cwd at Grasp start, not the index's `project.root`), `grasp/lib/grasp/application.ex` (record `home` at start), `command_test.exs`, README §PR mode, spec Part 4 if details differ.

**Interfaces (produced):**

```elixir
# Grasp.PullRequest
@type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})
@spec open(number :: pos_integer(), opts) :: {:ok, %{worktree: Path.t(), base: String.t(), head: String.t(), title: String.t(), url: String.t(), index: Path.t()}} | {:error, String.t()}
#   opts: root (host project root), runner (default System.cmd), gh (default "gh"), base_override.
#   Steps (each a runner call, stop on the first failure with the command's output):
#     gh pr view N --json baseRefName,headRefName,title,url  → decode
#     git fetch origin <base> <head>
#     worktree = root/.grasp/worktrees/pr-N: if absent `git worktree add <worktree> origin/<head>` (detached at the fetched head),
#       else `git -C <worktree> checkout --detach origin/<head>`
#     symlink root/deps → worktree/deps when worktree/deps is absent
#     build = worktree/_build/grasp: when absent and root/_build/dev exists, copy root/_build/dev → build (File.cp_r)
#     mix grasp.index --base origin/<base> --out root/.grasp/index.json --build-path <build>   (cwd: worktree, env MIX_ENV=dev)
@spec close(number, opts) :: :ok | {:error, String.t()}     # git worktree remove --force <worktree>; git worktree prune
# Mix.Tasks.Grasp.Pr: `mix grasp.pr N [--close]`; prints each step; Mix.raise on error.
# Grasp.Agent.Command: edit allowlist = "mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*),Bash(git fetch:*),Bash(gh pr view:*)"
#   PR recipe: run `mix grasp.pr N`; call reload_index; list_changes; set_cards one group per flow; edits go to project.root (the worktree).
# Grasp.Comments / Grasp.Session.Disk: files under Path.join(home, ".grasp/…") where home = Application.get_env(:grasp, :home) || File.cwd!() at Grasp start (config :grasp, home: nil default; the application sets it once when nil). Tests keep their explicit *_path/_dir overrides.
```

**Requirements:**

- `pull_request_test.exs`: a `tmp_dir` bare "origin" repository with a `main` and a `feature` branch and a clone as `root`; the fake `gh` answers `pr view 7` with `baseRefName main`, `headRefName feature`; the runner is real `git` for git commands and a recording stub for `mix grasp.index` (assert the argv, cwd and env); asserts the worktree exists detached at the fetched head, `deps` is a symlink, the build dir is seeded when `_build/dev` exists in root (create a marker file), and `close/2` removes it. `gh` failure → `{:error, output}`; running `open/2` twice reuses the worktree (checkout --detach).
- `command_test.exs`: the prompt names `mix grasp.pr` and no longer `gh pr checkout`/`git switch`; the allowlist string matches.
- The spec Part 4's worktree paragraph and the README §PR mode describe this; the old Known gap about switching the tree is removed from the 5.4 list (mark "closed in milestone 7").
- Gates; commit `Pull requests are reviewed from worktrees`.
