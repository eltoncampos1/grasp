# Grasp Viewer Core (Milestone 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A running Phoenix LiveView app, `mix grasp.serve --index PATH`, that renders functions from a Grasp index as a branching tree of cards: click a call, the callee opens as a child card; Cmd+K finds any function.

**Architecture:** `Grasp.IndexStore` loads the JSON index into `:persistent_term` and reloads it when the file's mtime changes. `Grasp.Session` is a GenServer per named session holding a forest of cards (pure operations live in `Grasp.Session.Forest`), broadcasting every change over PubSub. `GraspWeb.ReviewLive` subscribes to both, renders the sidebar (modules → functions), the recursive card tree and the palette, and translates clicks into session operations. `Grasp.Highlight` turns a function record into Makeup-highlighted HTML with clickable spans over each resolved call's range. Sessions are in-memory in this milestone; persistence, annotations and tours come in milestones 5 and 6 and extend the same forest.

**Tech Stack:** Elixir 1.20.4 / OTP 29, Phoenix ~> 1.8, phoenix_live_view ~> 1.2, phoenix_html ~> 4.3, Bandit ~> 1.12, Makeup ~> 1.2 + makeup_elixir ~> 1.0, esbuild ~> 0.10 (bundles JS and the hand-written CSS), lazy_html (tests). `{:grasp_index, path: "../grasp_index"}` for the reader.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 "grasp viewer": Session (forest only, no annotations/tour yet), Card tree, Layout, Page (sidebar shows modules instead of entry points until milestone 3; no Changes list, no tour bar), Card (no change badge, no Source/Diff toggle, no annotations yet), Highlighting (no ETS cache — computed per render, cheap), Command palette, Assets. Also the spec's reader storage decision: the index lives in `:persistent_term`.

## Global Constraints

- The viewer is a separate Mix project at `grasp/`; it is never a dependency of a target project. Its deps: phoenix, phoenix_html, phoenix_live_view, bandit, jason, makeup, makeup_elixir, esbuild (dev), lazy_html (test), grasp_index (path). No Tailwind, no gettext, no Ecto, no mailer.
- Binds to `127.0.0.1`; default port `4040`.
- Function ids are `"<module>.<name>/<arity>"` strings exactly as the index stores them. Card ids are positive integers unique within a session.
- Card tree semantics (spec): clicking a call opens the callee as a child of that card; clicking a call whose child is already open focuses that child; closing a card closes its subtree; collapsing hides the subtree behind a count; opening a caller from a root re-parents (caller becomes the new root, the card its child); from a non-root card it opens a new root tree `caller → function`; palette/sidebar open a new root (Shift+Enter: child of the focused card).
- Layout is pure CSS: a node is a horizontal flex of `[card][vertical stack of child nodes]`; cards have a fixed width (`--card-width: 40rem`); a connector joins parent to child.
- Every module has a `@moduledoc`; every public function has `@doc` and `@spec`, except HEEx function components (documented with `attr`/`slot`) and framework callbacks (`mount/3`, `handle_event/3`, `handle_info/2`, `render/1`, `init/1`, `handle_call/3`, `handle_info/2` in GenServers, Mix `run/1`). Comments only where the why is non-obvious. Never nest two modules in one file. Predicates end in `?`.
- HEEx: `{...}` for attribute and inline interpolation, `<%= %>` only for block constructs; conditional classes as lists; no `style=` attributes except injecting a CSS custom property.
- CSS: one hand-written `assets/css/app.css` with custom properties, dark theme; no hard-coded colours outside the `:root` token block.
- Run `mix format` in `grasp/` before every commit. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Public repo: no employer or third-party project names in code, fixtures, docs or commits. Fixtures use `SampleApp`.
- LiveView tests use `Phoenix.LiveViewTest` against the committed fixture index; each test uses its own session name (`"t-#{System.unique_integer([:positive])}"`) so tests can be `async: true`. Tests that reload the global index are `async: false`.

---

## File structure

```
grasp/
  mix.exs  .formatter.exs  README.md
  config/config.exs  config/dev.exs  config/test.exs  config/runtime.exs
  lib/grasp/application.ex         # supervision tree
  lib/grasp/index_store.ex         # Grasp.IndexStore — persistent_term + mtime poll + PubSub
  lib/grasp/session.ex             # Grasp.Session — GenServer per session, PubSub broadcasts, public API
  lib/grasp/session/forest.ex      # Grasp.Session.Forest — pure card-tree operations
  lib/grasp/highlight.ex           # Grasp.Highlight — Makeup HTML with clickable call spans
  lib/grasp_web.ex                 # use GraspWeb, :live_view | :html | :verified_routes
  lib/grasp_web/endpoint.ex
  lib/grasp_web/router.ex
  lib/grasp_web/error_html.ex
  lib/grasp_web/components/layouts.ex
  lib/grasp_web/components/layouts/root.html.heex
  lib/grasp_web/components/card_components.ex   # card, card_node, stub card, editor link
  lib/grasp_web/components/palette.ex           # palette dialog component
  lib/grasp_web/live/review_live.ex             # GraspWeb.ReviewLive
  lib/mix/tasks/grasp.serve.ex                  # Mix.Tasks.Grasp.Serve
  assets/js/app.js  assets/js/hooks/palette.js  assets/js/hooks/keys.js  assets/css/app.css
  priv/static/assets/   (build output, gitignored)  priv/static/favicon.ico (none needed)
  test/test_helper.exs  test/support/conn_case.ex
  test/fixtures/index.json                      # generated from grasp_index's sample_app
  test/grasp/index_store_test.exs  test/grasp/session/forest_test.exs  test/grasp/session_test.exs
  test/grasp/highlight_test.exs  test/grasp_web/live/review_live_test.exs  test/grasp_web/live/palette_test.exs
grasp_index/lib/grasp/index.ex                  # + functions_in_module/2
```

---

### Task 1: Phoenix app scaffold

**Files:**
- Create: `grasp/mix.exs`, `grasp/.formatter.exs`, `grasp/config/{config,dev,test,runtime}.exs`, `grasp/lib/grasp/application.ex`, `grasp/lib/grasp_web.ex`, `grasp/lib/grasp_web/endpoint.ex`, `grasp/lib/grasp_web/router.ex`, `grasp/lib/grasp_web/error_html.ex`, `grasp/lib/grasp_web/components/layouts.ex`, `grasp/lib/grasp_web/components/layouts/root.html.heex`, `grasp/lib/grasp_web/live/review_live.ex` (placeholder), `grasp/assets/js/app.js`, `grasp/assets/css/app.css`, `grasp/test/test_helper.exs`, `grasp/test/support/conn_case.ex`, `grasp/README.md`
- Test: `grasp/test/grasp_web/live/review_live_test.exs` (smoke)
- Modify: root `.gitignore` (add `/grasp/priv/static/assets/` — already present as `/grasp/priv/static/assets/`; verify)

**Interfaces:**
- Produces: the `:grasp` OTP app with `GraspWeb.Endpoint` on 127.0.0.1:4040 (dev) and `GraspWeb.ReviewLive` at `/` and `/s/:name`; `GraspWeb.ConnCase`; config keys `:grasp, :index_path` and `:grasp, :editor` (both nil by default; test sets `index_path: "test/fixtures/index.json"` — the file arrives in Task 2, so in this task `Grasp.IndexStore` does not exist yet and nothing reads the key).

- [ ] **Step 1: Write the smoke test**

`grasp/test/grasp_web/live/review_live_test.exs`:

```elixir
defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  test "renders the app shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Grasp"
  end
end
```

- [ ] **Step 2: Create the project files**

`grasp/mix.exs`:

```elixir
defmodule Grasp.MixProject do
  use Mix.Project

  def project do
    [
      app: :grasp,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [mod: {Grasp.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  def cli do
    [preferred_envs: [test: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:makeup, "~> 1.2"},
      {:makeup_elixir, "~> 1.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:grasp_index, path: "../grasp_index"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      "assets.build": ["esbuild grasp"],
      "assets.deploy": ["esbuild grasp --minify"]
    ]
  end
end
```

`grasp/.formatter.exs`:

```elixir
[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
```

`grasp/config/config.exs`:

```elixir
import Config

config :grasp, GraspWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: GraspWeb.ErrorHTML], layout: false],
  pubsub_server: Grasp.PubSub,
  live_view: [signing_salt: "grasp-live-view-salt"]

config :grasp, index_path: nil, editor: nil

config :esbuild,
  version: "0.25.4",
  grasp: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
```

`grasp/config/dev.exs`:

```elixir
import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-key-base-0000",
  watchers: [esbuild: {Esbuild, :install_and_run, [:grasp, ~w(--sourcemap=inline --watch)]}]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
```

`grasp/config/test.exs`:

```elixir
import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  server: false,
  secret_key_base: "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-00"

config :grasp, index_path: "test/fixtures/index.json"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
```

`grasp/config/runtime.exs` (read by `mix grasp.serve`, Task 7, through environment variables):

```elixir
import Config

if index = System.get_env("GRASP_INDEX") do
  config :grasp, index_path: index
end

if editor = System.get_env("GRASP_EDITOR") do
  config :grasp, editor: editor
end

if port = System.get_env("GRASP_PORT") do
  config :grasp, GraspWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
end
```

`grasp/lib/grasp/application.ex`:

```elixir
defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of the Grasp viewer: PubSub, the index store, the session registry
  and supervisor, and the endpoint.

  Later tasks add `Grasp.IndexStore` and the session supervisor; in this task only PubSub
  and the endpoint start.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      GraspWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Grasp.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GraspWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

`grasp/lib/grasp_web.ex`:

```elixir
defmodule GraspWeb do
  @moduledoc """
  Entry points for the web layer: `use GraspWeb, :live_view`, `:html` or `:verified_routes`.
  """

  @doc "Static paths served by `Plug.Static`."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: GraspWeb.Endpoint,
        router: GraspWeb.Router,
        statics: GraspWeb.static_paths()
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      unquote(verified_routes())
    end
  end

  @doc false
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
```

`grasp/lib/grasp_web/endpoint.ex`:

```elixir
defmodule GraspWeb.Endpoint do
  @moduledoc "HTTP endpoint of the Grasp viewer. Serves the bundled assets and the LiveView socket."

  use Phoenix.Endpoint, otp_app: :grasp

  @session_options [store: :cookie, key: "_grasp_key", signing_salt: "grasp-session-salt", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/", from: :grasp, gzip: false, only: GraspWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GraspWeb.Router
end
```

`grasp/lib/grasp_web/router.ex`:

```elixir
defmodule GraspWeb.Router do
  @moduledoc "Routes: the review page for the default session and for a named session."

  use GraspWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {GraspWeb.Layouts, :root}
  end

  scope "/", GraspWeb do
    pipe_through :browser

    live "/", ReviewLive
    live "/s/:name", ReviewLive
  end
end
```

`grasp/lib/grasp_web/error_html.ex`:

```elixir
defmodule GraspWeb.ErrorHTML do
  @moduledoc "Renders plain status messages for HTTP errors."

  use GraspWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
```

`grasp/lib/grasp_web/components/layouts.ex`:

```elixir
defmodule GraspWeb.Layouts do
  @moduledoc """
  The root layout. Inlines Makeup's stylesheet so token colours ship without a build step;
  everything else comes from the esbuild bundle.
  """

  use GraspWeb, :html

  @makeup_css Makeup.stylesheet(:monokai_style, "hl")

  embed_templates "layouts/*"

  @doc "Makeup's token stylesheet, scoped under `.hl`."
  @spec makeup_css() :: String.t()
  def makeup_css, do: @makeup_css
end
```

The module is `GraspWeb.Layouts` (Phoenix convention) even though the file lives under `components/`.

`grasp/lib/grasp_web/components/layouts/root.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
    <title>Grasp</title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    {raw("<style>" <> makeup_css() <> "</style>")}
    <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
    </script>
  </head>
  <body>
    {@inner_content}
  </body>
</html>
```

`grasp/lib/grasp_web/live/review_live.ex` (placeholder for this task; Task 5 replaces it):

```elixir
defmodule GraspWeb.ReviewLive do
  @moduledoc "The review page: sidebar, card canvas and palette. Filled in by later tasks."

  use GraspWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app">
      <h1 class="brand">Grasp</h1>
    </main>
    """
  end
end
```

`grasp/assets/js/app.js`:

```js
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import "../css/app.css"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: {}})

liveSocket.connect()
window.liveSocket = liveSocket
```

`grasp/assets/css/app.css` (tokens and shell only; Task 5 adds the tree):

```css
:root {
  color-scheme: dark;
  --bg: #1b1d22;
  --bg-raised: #22252b;
  --bg-sunken: #15171b;
  --border: #33373f;
  --fg: #e6e6e6;
  --fg-muted: #9aa0a6;
  --accent: #7aa2f7;
  --accent-soft: color-mix(in oklch, var(--accent) 25%, transparent);
  --focus: #e0af68;
  --danger: #f7768e;
  --radius: 6px;
  --space-xs: 0.25rem;
  --space-s: 0.5rem;
  --space-m: 1rem;
  --space-l: 1.5rem;
  --card-width: 40rem;
  --sidebar-width: 18rem;
  --mono: ui-monospace, "JetBrains Mono", Menlo, monospace;
  --sans: system-ui, sans-serif;
}

* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font-family: var(--sans); font-size: 14px; }
button { font: inherit; color: inherit; background: none; border: 0; cursor: pointer; }
.brand { margin: 0; padding: var(--space-s) var(--space-m); font-size: 1rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-muted); }
.app { display: grid; grid-template-columns: var(--sidebar-width) 1fr; height: 100vh; }
```

`grasp/test/test_helper.exs`:

```elixir
ExUnit.start()
```

`grasp/test/support/conn_case.ex`:

```elixir
defmodule GraspWeb.ConnCase do
  @moduledoc "Test case for LiveView tests: a connection plus `Phoenix.LiveViewTest`."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint GraspWeb.Endpoint
      use GraspWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

`grasp/README.md`:

```markdown
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
```

- [ ] **Step 3: Fetch deps, build assets, run the smoke test**

Run from `grasp/`: `mix deps.get && mix compile --warnings-as-errors && mix assets.build && mix test`
Expected: esbuild binary downloads once; `priv/static/assets/app.{js,css}` produced; 1 test, 0 failures. If `Makeup.stylesheet/2` is not exported in the installed version, use `Makeup.Styles.HTML.StyleMap.monokai_style() |> Makeup.Styles.HTML.Style.stylesheet("hl")` and say so in the report.

Check `git status` shows no `priv/static/assets` files (gitignored by `/grasp/priv/static/assets/` in the root `.gitignore`).

- [ ] **Step 4: Format and commit**

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Scaffold the grasp viewer Phoenix app

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Index store and the fixture index

**Files:**
- Modify: `grasp_index/lib/grasp/index.ex` (add `functions_in_module/2`), `grasp_index/test/grasp/index_test.exs`
- Create: `grasp/lib/grasp/index_store.ex`, `grasp/test/fixtures/index.json`, `grasp/test/grasp/index_store_test.exs`
- Modify: `grasp/lib/grasp/application.ex` (start the store), `grasp/test/test_helper.exs`

**Interfaces:**
- Produces: `Grasp.Index.functions_in_module(index, module_name) :: [function_record()]` sorted by `span.start_line`.
- Produces: `Grasp.IndexStore.get/0 :: Grasp.Index.t() | nil`, `path/0`, `load(path) :: :ok | {:error, term()}` (loads, stores in `:persistent_term`, broadcasts), `reload/0`, `subscribe/0` (topic `"index"`, message `:index_reloaded`).

- [ ] **Step 1: Reader addition (grasp_index), test first**

Append to `grasp_index/test/grasp/index_test.exs` inside the module:

```elixir
  test "functions_in_module/2 lists a module's functions in source order", %{index: index} do
    assert ids(Index.functions_in_module(index, "MyApp.Wallets")) == ["MyApp.Wallets.credit/3", "MyApp.Wallets.debit/3"]
    assert Index.functions_in_module(index, "Nope") == []
  end
```

(Both fixture records have `start_line` 1, so also give `debit/3` a `"span" => %{"start_line" => 5, "end_line" => 6}` in the test document so the ordering assertion is meaningful — credit (line 1) before debit (line 5).)

Run `cd grasp_index && mix test test/grasp/index_test.exs` → fails (undefined function). Implement in `grasp_index/lib/grasp/index.ex`:

```elixir
  @doc "Functions defined in `module`, in source order."
  @spec functions_in_module(t(), String.t()) :: [function_record()]
  def functions_in_module(%__MODULE__{} = index, module) do
    index.functions
    |> Map.values()
    |> Enum.filter(&(&1["module"] == module))
    |> Enum.sort_by(&{&1["span"]["start_line"], &1["id"]})
  end
```

Run again → passes. Format and commit in the grasp repo: `Add Grasp.Index.functions_in_module/2`.

- [ ] **Step 2: Generate the fixture index**

```bash
cd ~/repos/grasp/grasp_index/test/fixtures/sample_app && MIX_ENV=dev mix grasp.index --out ../../../../grasp/test/fixtures/index.json
```

Then edit `grasp/test/fixtures/index.json`: set `"project"."root"` to `"/tmp/sample_app"`, set `"git"` to `null`, set `"generated_at"` to `"2026-09-15T00:00:00Z"`, and add one hidden call to `SampleApp.Greeter.greet_all/1`: `"hidden_calls": [{"target": "SampleApp.Formatter.shout/1", "kind": "remote", "line": 15}]`. Keep the file pretty-printed. Sanity-check with `jq '.functions | length' grasp/test/fixtures/index.json` → 5.

- [ ] **Step 3: Write the IndexStore tests**

`grasp/test/grasp/index_store_test.exs`:

```elixir
defmodule Grasp.IndexStoreTest do
  use ExUnit.Case, async: false

  alias Grasp.IndexStore

  @fixture Path.expand("../fixtures/index.json", __DIR__)

  setup do
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)
    :ok
  end

  test "the fixture index is loaded at boot" do
    assert %Grasp.Index{} = index = IndexStore.get()
    assert {:ok, _} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
    assert IndexStore.path() == @fixture
  end

  test "load/1 replaces the index and broadcasts" do
    IndexStore.subscribe()
    path = tmp_copy(fn doc -> put_in(doc, ["project", "app"], "other_app") end)

    assert :ok = IndexStore.load(path)
    assert_receive :index_reloaded
    assert IndexStore.get().project["app"] == "other_app"
  end

  test "load/1 keeps the previous index when the file is unreadable" do
    before = IndexStore.get()
    assert {:error, _} = IndexStore.load(@fixture <> ".missing")
    assert IndexStore.get() == before
  end

  test "a changed mtime triggers a reload" do
    path = tmp_copy(& &1)
    :ok = IndexStore.load(path)
    IndexStore.subscribe()

    doc = path |> File.read!() |> Jason.decode!() |> put_in(["project", "app"], "touched")
    File.write!(path, Jason.encode!(doc))
    future = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> Kernel.+(5)
    File.touch!(path, future)

    send(IndexStore, :poll)
    assert_receive :index_reloaded, 1_000
    assert IndexStore.get().project["app"] == "touched"
  end

  defp tmp_copy(transform) do
    path = Path.join(System.tmp_dir!(), "grasp-store-#{System.unique_integer([:positive])}.json")
    doc = @fixture |> File.read!() |> Jason.decode!() |> transform.()
    File.write!(path, Jason.encode!(doc))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
```

- [ ] **Step 4: Run to verify failure**

`cd grasp && mix test test/grasp/index_store_test.exs` → `Grasp.IndexStore` undefined.

- [ ] **Step 5: Implement the store, start it, load the fixture in tests**

`grasp/lib/grasp/index_store.ex`:

```elixir
defmodule Grasp.IndexStore do
  @moduledoc """
  Holds the loaded `Grasp.Index` in `:persistent_term` and reloads it when the index
  file changes.

  The index for a mid-sized project is several megabytes; `:persistent_term` keeps it
  off-heap so every LiveView reads it without copying. The store polls the file's mtime
  every two seconds — `mix grasp.index` rewrites the whole file, so an mtime change is
  the signal — and broadcasts `:index_reloaded` on the `"index"` topic after a successful
  reload. A failed load (missing or invalid file) keeps the previous index and logs.
  """

  use GenServer
  require Logger

  @key {__MODULE__, :index}
  @topic "index"
  @poll_ms 2_000

  @doc "Starts the store; `:path` defaults to the `:grasp, :index_path` config."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The loaded index, or `nil` when none has been loaded."
  @spec get() :: Grasp.Index.t() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc "The path currently watched, or `nil`."
  @spec path() :: String.t() | nil
  def path, do: GenServer.call(__MODULE__, :path)

  @doc "Loads `path`, replaces the index and starts watching that path."
  @spec load(String.t()) :: :ok | {:error, term()}
  def load(path), do: GenServer.call(__MODULE__, {:load, path})

  @doc "Reloads the watched path now."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Subscribes the caller to `:index_reloaded` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Application.get_env(:grasp, :index_path))
    state = %{path: nil, mtime: nil}

    state =
      case path && do_load(path, state) do
        {:ok, state} -> state
        {:error, reason} -> Logger.warning("grasp: could not load index #{path}: #{inspect(reason)}"); %{state | path: path}
        nil -> state
      end

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:load, path}, _from, state) do
    case do_load(path, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, %{path: nil} = state), do: {:reply, {:error, :no_path}, state}
  def handle_call(:reload, _from, state), do: handle_call({:load, state.path}, nil, state)

  @impl true
  def handle_info(:poll, %{path: nil} = state) do
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    state =
      case File.stat(state.path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime != state.mtime ->
          case do_load(state.path, state) do
            {:ok, state} -> state
            {:error, reason} -> Logger.warning("grasp: reload failed: #{inspect(reason)}"); state
          end

        _ ->
          state
      end

    schedule_poll()
    {:noreply, state}
  end

  defp do_load(path, state) do
    with {:ok, index} <- Grasp.Index.load(path),
         {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix) do
      :persistent_term.put(@key, index)
      Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :index_reloaded)
      {:ok, %{state | path: path, mtime: mtime}}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
end
```

In `grasp/lib/grasp/application.ex`, add `Grasp.IndexStore` between PubSub and the endpoint: `{Grasp.IndexStore, []}`. Update its moduledoc's second paragraph to say the session supervisor arrives in Task 3.

`config/test.exs` already points `index_path` at `test/fixtures/index.json`, so the store loads the fixture at boot. No change to `test_helper.exs` is needed; remove the "Modify test_helper" item if nothing changes.

- [ ] **Step 6: Run the tests**

`cd grasp && mix test` → all pass (smoke + 4 store tests). The mtime test sends `:poll` directly so it doesn't wait two seconds.

- [ ] **Step 7: Format and commit**

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Add Grasp.IndexStore: persistent_term index with mtime reload

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Session forest and session server

**Files:**
- Create: `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`
- Modify: `grasp/lib/grasp/application.ex` (Registry + DynamicSupervisor)
- Test: `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs`

**Interfaces:**
- Produces `Grasp.Session.Forest` (struct `%{roots: [id], cards: %{id => card}, focus: id | nil, next_id: pos_integer}`, card `%{id, function_id, parent_id, children: [id], opened_by: String.t() | nil, collapsed: boolean}`) with pure functions: `new/0`, `open_root/2 :: {t, id}`, `open_child/3 :: {t, id}`, `open_caller/3 :: {t, id}`, `close/2`, `focus/2`, `toggle_collapse/2`, `move_focus/2` (dir `:parent | :child | :next | :prev`), `card/2 :: card | nil`, `root?/2`, `depth/2`, `subtree_size/2`.
- Produces `Grasp.Session` API, all taking the session `name` (string) first and returning the forest: `ensure/1`, `subscribe/1`, `get/1`, `open_root/2`, `open_child/3`, `open_caller/3`, `close/2`, `focus/2`, `toggle_collapse/2`, `move_focus/2`. Broadcast message `{:session, name, forest}` on topic `"session:" <> name`.

- [ ] **Step 1: Forest tests**

`grasp/test/grasp/session/forest_test.exs`:

```elixir
defmodule Grasp.Session.ForestTest do
  use ExUnit.Case, async: true

  alias Grasp.Session.Forest

  test "open_root/2 appends a focused root" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_root(forest, "B.g/0")

    assert forest.roots == [a, b]
    assert forest.focus == b
    assert %{function_id: "B.g/0", parent_id: nil, children: [], opened_by: nil, collapsed: false} = Forest.card(forest, b)
  end

  test "open_child/3 nests under the parent and focuses the child; reopening focuses the existing child" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, a, "C.h/2")
    {forest, b_again} = Forest.open_child(forest, a, "B.g/0")

    assert b_again == b
    assert Forest.card(forest, a).children == [b, c]
    assert Forest.card(forest, b).parent_id == a
    assert Forest.card(forest, b).opened_by == "B.g/0"
    assert forest.focus == b
    assert Forest.depth(forest, b) == 1
  end

  test "close/2 removes the subtree and moves focus to the parent" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")

    forest = Forest.close(forest, b)

    assert Forest.card(forest, b) == nil
    assert Forest.card(forest, c) == nil
    assert Forest.card(forest, a).children == []
    assert forest.focus == a
  end

  test "closing a root drops it from roots and clears focus when nothing is left" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    forest = Forest.close(forest, a)
    assert forest.roots == []
    assert forest.focus == nil
  end

  test "toggle_collapse/2 flips the flag and subtree_size/2 counts descendants" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, _c} = Forest.open_child(forest, b, "C.h/2")

    assert Forest.subtree_size(forest, a) == 2
    assert Forest.toggle_collapse(forest, a) |> Forest.card(a) |> Map.fetch!(:collapsed)
  end

  test "open_caller/3 on a root re-parents: the caller becomes the root" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, _b} = Forest.open_root(forest, "B.g/0")
    {forest, caller} = Forest.open_caller(forest, a, "Web.Controller.show/2")

    assert forest.roots |> Enum.at(0) == caller
    assert Forest.card(forest, caller).children == [a]
    assert Forest.card(forest, a).parent_id == caller
    assert Forest.card(forest, a).opened_by == "A.f/1"
    assert forest.focus == caller
    assert Forest.root?(forest, caller)
    refute Forest.root?(forest, a)
  end

  test "open_caller/3 on a non-root opens a new root tree caller → function" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, caller} = Forest.open_caller(forest, b, "Other.k/0")

    assert forest.roots == [a, caller]
    [copy] = Forest.card(forest, caller).children
    assert Forest.card(forest, copy).function_id == "B.g/0"
    assert Forest.card(forest, a).children == [b]
    assert forest.focus == caller
  end

  test "move_focus/2 walks parent, child and siblings; collapsed subtrees are skipped" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, a, "C.h/2")
    {forest, d} = Forest.open_root(forest, "D.i/0")

    forest = Forest.focus(forest, b)
    assert Forest.move_focus(forest, :next).focus == c
    assert Forest.move_focus(forest, :prev).focus == b
    assert Forest.move_focus(forest, :parent).focus == a
    assert forest |> Forest.focus(a) |> Forest.move_focus(:child) |> Map.fetch!(:focus) == b
    assert forest |> Forest.focus(a) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == d
    assert forest |> Forest.focus(a) |> Forest.toggle_collapse(a) |> Forest.move_focus(:child) |> Map.fetch!(:focus) == a
    assert Forest.move_focus(%{forest | focus: nil}, :next).focus == a
  end
end
```

- [ ] **Step 2: Run to verify failure**

`cd grasp && mix test test/grasp/session/forest_test.exs` → `Grasp.Session.Forest` undefined.

- [ ] **Step 3: Implement the forest**

`grasp/lib/grasp/session/forest.ex`:

```elixir
defmodule Grasp.Session.Forest do
  @moduledoc """
  The tree of cards a review session shows, as pure data with pure operations.

  A card shows one function. Cards form a forest: `roots` are the entry cards in column
  zero, and each card lists its `children` — callees opened from it. `opened_by` records
  which call target opened a card, so the parent can mark that call while the child is
  open. Focus is a single card id. Closing a card removes its subtree; collapsing hides
  it. Opening a caller from a root re-parents the root under the caller; from a non-root
  card it starts a new root tree so the original branch is left intact.
  """

  defstruct roots: [], cards: %{}, focus: nil, next_id: 1

  @type id :: pos_integer()
  @type card :: %{
          id: id(),
          function_id: String.t(),
          parent_id: id() | nil,
          children: [id()],
          opened_by: String.t() | nil,
          collapsed: boolean()
        }
  @type t :: %__MODULE__{roots: [id()], cards: %{id() => card()}, focus: id() | nil, next_id: id()}
  @type direction :: :parent | :child | :next | :prev

  @doc "An empty forest."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The card with `id`, or nil."
  @spec card(t(), id()) :: card() | nil
  def card(%__MODULE__{} = forest, id), do: Map.get(forest.cards, id)

  @doc "Whether `id` is a root card."
  @spec root?(t(), id()) :: boolean()
  def root?(%__MODULE__{} = forest, id), do: id in forest.roots

  @doc "Number of ancestors of `id`."
  @spec depth(t(), id()) :: non_neg_integer()
  def depth(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      %{parent_id: nil} -> 0
      %{parent_id: parent} -> 1 + depth(forest, parent)
      nil -> 0
    end
  end

  @doc "Number of descendants of `id`."
  @spec subtree_size(t(), id()) :: non_neg_integer()
  def subtree_size(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil -> 0
      %{children: children} -> length(children) + Enum.sum(Enum.map(children, &subtree_size(forest, &1)))
    end
  end

  @doc "Appends a new root showing `function_id` and focuses it."
  @spec open_root(t(), String.t()) :: {t(), id()}
  def open_root(%__MODULE__{} = forest, function_id) do
    {forest, id} = add_card(forest, function_id, nil, nil)
    {%{forest | roots: forest.roots ++ [id], focus: id}, id}
  end

  @doc """
  Opens `function_id` as a child of `parent_id`, or focuses the existing child that shows
  it. Returns the child id.
  """
  @spec open_child(t(), id(), String.t()) :: {t(), id()}
  def open_child(%__MODULE__{} = forest, parent_id, function_id) do
    parent = Map.fetch!(forest.cards, parent_id)

    case Enum.find(parent.children, &(card(forest, &1).function_id == function_id)) do
      nil ->
        {forest, id} = add_card(forest, function_id, parent_id, function_id)
        parent = %{parent | children: parent.children ++ [id]}
        {%{forest | cards: Map.put(forest.cards, parent_id, parent), focus: id}, id}

      existing ->
        {%{forest | focus: existing}, existing}
    end
  end

  @doc """
  Opens `caller_id` as the caller of `card_id`. On a root, the caller becomes the new root
  with the card as its child; otherwise a new root tree `caller → function` is opened.
  """
  @spec open_caller(t(), id(), String.t()) :: {t(), id()}
  def open_caller(%__MODULE__{} = forest, card_id, caller_id) do
    card = Map.fetch!(forest.cards, card_id)

    if root?(forest, card_id) do
      {forest, new_root} = add_card(forest, caller_id, nil, nil)
      caller = %{Map.fetch!(forest.cards, new_root) | children: [card_id]}
      card = %{card | parent_id: new_root, opened_by: card.function_id}
      roots = Enum.map(forest.roots, &if(&1 == card_id, do: new_root, else: &1))
      cards = forest.cards |> Map.put(new_root, caller) |> Map.put(card_id, card)
      {%{forest | roots: roots, cards: cards, focus: new_root}, new_root}
    else
      {forest, new_root} = open_root(forest, caller_id)
      {forest, _copy} = open_child(forest, new_root, card.function_id)
      {%{forest | focus: new_root}, new_root}
    end
  end

  @doc "Removes `id` and its subtree; focus moves to the parent (or nil for a root)."
  @spec close(t(), id()) :: t()
  def close(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil ->
        forest

      card ->
        removed = [id | descendants(forest, id)]
        cards = Map.drop(forest.cards, removed)

        cards =
          case card.parent_id do
            nil -> cards
            parent_id -> Map.update!(cards, parent_id, &%{&1 | children: List.delete(&1.children, id)})
          end

        focus = if forest.focus in removed, do: card.parent_id, else: forest.focus
        %{forest | roots: List.delete(forest.roots, id), cards: cards, focus: focus}
    end
  end

  @doc "Focuses `id` if it exists."
  @spec focus(t(), id()) :: t()
  def focus(%__MODULE__{} = forest, id), do: if(Map.has_key?(forest.cards, id), do: %{forest | focus: id}, else: forest)

  @doc "Shows or hides the subtree of `id`."
  @spec toggle_collapse(t(), id()) :: t()
  def toggle_collapse(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil -> forest
      card -> %{forest | cards: Map.put(forest.cards, id, %{card | collapsed: not card.collapsed})}
    end
  end

  @doc "Moves focus to the parent, first visible child, next or previous sibling."
  @spec move_focus(t(), direction()) :: t()
  def move_focus(%__MODULE__{focus: nil, roots: [first | _]} = forest, _dir), do: %{forest | focus: first}
  def move_focus(%__MODULE__{focus: nil} = forest, _dir), do: forest

  def move_focus(%__MODULE__{} = forest, dir) do
    card = Map.fetch!(forest.cards, forest.focus)

    target =
      case dir do
        :parent -> card.parent_id
        :child -> if card.collapsed, do: nil, else: List.first(card.children)
        :next -> neighbour(siblings(forest, card), card.id, 1)
        :prev -> neighbour(siblings(forest, card), card.id, -1)
      end

    if target, do: %{forest | focus: target}, else: forest
  end

  defp siblings(forest, %{parent_id: nil}), do: forest.roots
  defp siblings(forest, %{parent_id: parent_id}), do: Map.fetch!(forest.cards, parent_id).children

  defp neighbour(list, id, offset) do
    index = Enum.find_index(list, &(&1 == id)) + offset
    if index >= 0, do: Enum.at(list, index)
  end

  defp descendants(forest, id) do
    children = card(forest, id).children
    children ++ Enum.flat_map(children, &descendants(forest, &1))
  end

  defp add_card(forest, function_id, parent_id, opened_by) do
    id = forest.next_id
    card = %{id: id, function_id: function_id, parent_id: parent_id, children: [], opened_by: opened_by, collapsed: false}
    {%{forest | cards: Map.put(forest.cards, id, card), next_id: id + 1}, id}
  end
end
```

Run `mix test test/grasp/session/forest_test.exs` → 8 tests pass.

- [ ] **Step 4: Session server tests**

`grasp/test/grasp/session_test.exs`:

```elixir
defmodule Grasp.SessionTest do
  use ExUnit.Case, async: true

  alias Grasp.Session
  alias Grasp.Session.Forest

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    :ok = Session.ensure(name)
    %{name: name}
  end

  test "ensure/1 is idempotent and get/1 starts empty", %{name: name} do
    assert :ok = Session.ensure(name)
    assert %Forest{roots: [], cards: %{}, focus: nil} = Session.get(name)
  end

  test "operations mutate the forest and broadcast it", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    [root] = forest.roots
    assert_receive {:session, ^name, ^forest}

    forest = Session.open_child(name, root, "SampleApp.Formatter.wrap/1")
    [child] = Forest.card(forest, root).children
    assert Forest.card(forest, child).function_id == "SampleApp.Formatter.wrap/1"
    assert_receive {:session, ^name, ^forest}

    forest = Session.toggle_collapse(name, root)
    assert Forest.card(forest, root).collapsed

    forest = Session.move_focus(name, :parent)
    assert forest.focus == root

    forest = Session.close(name, root)
    assert forest.roots == []
    assert Session.get(name) == forest
  end

  test "sessions are isolated by name", %{name: name} do
    other = name <> "-other"
    :ok = Session.ensure(other)
    Session.open_root(name, "A.f/0")
    assert Session.get(other).roots == []
  end
end
```

- [ ] **Step 5: Implement the session server and supervisor**

`grasp/lib/grasp/session.ex`:

```elixir
defmodule Grasp.Session do
  @moduledoc """
  One review session: a named GenServer owning a `Grasp.Session.Forest`.

  The browser and (in a later milestone) the MCP server both mutate a session through this
  API, so state lives here rather than in a LiveView. Every mutation broadcasts
  `{:session, name, forest}` on the `"session:<name>"` topic; subscribers re-render from
  the forest they receive. Sessions are started on demand under `Grasp.SessionSupervisor`
  and found through `Grasp.SessionRegistry`. Persistence to disk arrives in milestone 5.
  """

  use GenServer

  alias Grasp.Session.Forest

  @type name :: String.t()

  @doc "Starts the session named `name` if it is not running."
  @spec ensure(name()) :: :ok
  def ensure(name) do
    case DynamicSupervisor.start_child(Grasp.SessionSupervisor, {__MODULE__, name}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def child_spec(name), do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc "Subscribes the caller to `{:session, name, forest}` broadcasts."
  @spec subscribe(name()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(Grasp.PubSub, topic(name))

  @doc "The current forest."
  @spec get(name()) :: Forest.t()
  def get(name), do: GenServer.call(via(name), :get)

  @doc "Opens a new root card."
  @spec open_root(name(), String.t()) :: Forest.t()
  def open_root(name, function_id), do: mutate(name, &Forest.open_root(&1, function_id))

  @doc "Opens (or focuses) `function_id` as a child of `card_id`."
  @spec open_child(name(), Forest.id(), String.t()) :: Forest.t()
  def open_child(name, card_id, function_id), do: mutate(name, &Forest.open_child(&1, card_id, function_id))

  @doc "Opens `caller_id` as the caller of `card_id`."
  @spec open_caller(name(), Forest.id(), String.t()) :: Forest.t()
  def open_caller(name, card_id, caller_id), do: mutate(name, &Forest.open_caller(&1, card_id, caller_id))

  @doc "Closes `card_id` and its subtree."
  @spec close(name(), Forest.id()) :: Forest.t()
  def close(name, card_id), do: mutate(name, &Forest.close(&1, card_id))

  @doc "Focuses `card_id`."
  @spec focus(name(), Forest.id()) :: Forest.t()
  def focus(name, card_id), do: mutate(name, &Forest.focus(&1, card_id))

  @doc "Collapses or expands `card_id`."
  @spec toggle_collapse(name(), Forest.id()) :: Forest.t()
  def toggle_collapse(name, card_id), do: mutate(name, &Forest.toggle_collapse(&1, card_id))

  @doc "Moves focus in `direction`."
  @spec move_focus(name(), Forest.direction()) :: Forest.t()
  def move_focus(name, direction), do: mutate(name, &Forest.move_focus(&1, direction))

  @impl true
  def init(name), do: {:ok, %{name: name, forest: Forest.new()}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.forest, state}

  def handle_call({:mutate, fun}, _from, state) do
    forest =
      case fun.(state.forest) do
        {%Forest{} = forest, _id} -> forest
        %Forest{} = forest -> forest
      end

    Phoenix.PubSub.broadcast(Grasp.PubSub, topic(state.name), {:session, state.name, forest})
    {:reply, forest, %{state | forest: forest}}
  end

  defp mutate(name, fun), do: GenServer.call(via(name), {:mutate, fun})
  defp via(name), do: {:via, Registry, {Grasp.SessionRegistry, name}}
  defp topic(name), do: "session:" <> name
end
```

In `grasp/lib/grasp/application.ex`, children become:

```elixir
    children = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      {Grasp.IndexStore, []},
      {Registry, keys: :unique, name: Grasp.SessionRegistry},
      {DynamicSupervisor, name: Grasp.SessionSupervisor, strategy: :one_for_one},
      GraspWeb.Endpoint
    ]
```

and the moduledoc's second paragraph is removed (the tree is now complete for this milestone).

- [ ] **Step 6: Run, format, commit**

`cd grasp && mix test` → all pass. Then:

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Add Grasp.Session with a pure card forest and PubSub broadcasts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Highlighting with clickable call spans

**Files:**
- Create: `grasp/lib/grasp/highlight.ex`
- Test: `grasp/test/grasp/highlight_test.exs`

**Interfaces:**
- Produces: `Grasp.Highlight.render(record :: map(), opts) :: Phoenix.HTML.safe()` where `record` is an index function record (string keys) and `opts` are `card_id: integer`, `open_targets: [String.t()]` (call targets whose child card is open), `external?: (String.t() -> boolean)` (true when the target is not in the index). Output: one `<span class="line" data-line="N"><span class="ln">N</span>…</span>\n` per source line; each call range wrapped as `<span class="call" data-target="T" data-open="true|false" data-external="true|false" phx-click="open_call" phx-value-card="ID" phx-value-target="T">…</span>`; tokens inside carry Makeup's short classes (`<span class="nc">Enum</span>`), text HTML-escaped. Lines are numbered from `record["span"]["start_line"]`.

- [ ] **Step 1: Tests**

`grasp/test/grasp/highlight_test.exs`:

```elixir
defmodule Grasp.HighlightTest do
  use ExUnit.Case, async: true

  alias Grasp.Highlight

  @record %{
    "id" => "Sample.run/1",
    "span" => %{"start_line" => 10, "end_line" => 12},
    "source" => "def run(x) do\n  Enum.map(x, &g/1)\n  <b>\nend",
    "calls" => [
      %{"target" => "Enum.map/2", "kind" => "remote", "range" => %{"start" => [11, 3], "end" => [11, 11]}},
      %{"target" => "Sample.g/1", "kind" => "local", "range" => %{"start" => [11, 16], "end" => [11, 17]}}
    ]
  }

  defp render(opts \\ []) do
    opts = Keyword.merge([card_id: 7, open_targets: [], external?: fn _ -> false end], opts)
    @record |> Highlight.render(opts) |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()
  end

  test "numbers lines from the span start and escapes source text" do
    html = render()
    assert LazyHTML.query(html, "span.line[data-line='10'] .ln") |> LazyHTML.text() == "10"
    assert LazyHTML.query(html, "span.line[data-line='12']") |> LazyHTML.text() =~ "<b>"
    assert LazyHTML.query(html, "span.line") |> Enum.count() == 4
  end

  test "wraps each call range in a clickable span covering exactly the callee" do
    html = render(open_targets: ["Enum.map/2"])
    [map] = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()

    assert LazyHTML.text(map) == "Enum.map"
    assert LazyHTML.attribute(map, "phx-click") == ["open_call"]
    assert LazyHTML.attribute(map, "phx-value-card") == ["7"]
    assert LazyHTML.attribute(map, "data-open") == ["true"]
    assert LazyHTML.query(map, "span.nc") |> LazyHTML.text() == "Enum"

    [g] = LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> Enum.to_list()
    assert LazyHTML.text(g) == "g"
    assert LazyHTML.attribute(g, "data-open") == ["false"]
  end

  test "marks external targets" do
    html = render(external?: &(&1 == "Enum.map/2"))
    assert LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> LazyHTML.attribute("data-external") == ["true"]
    assert LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> LazyHTML.attribute("data-external") == ["false"]
  end

  test "a range spanning two lines produces one call span per line" do
    record = %{
      "id" => "S.f/0",
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def f do\n  Enum\n  .map([], & &1)\nend",
      "calls" => [%{"target" => "Enum.map/2", "kind" => "remote", "range" => %{"start" => [2, 3], "end" => [3, 7]}}]
    }

    html = record |> Highlight.render(card_id: 1, open_targets: [], external?: fn _ -> false end) |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()
    spans = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()
    assert Enum.map(spans, &LazyHTML.text/1) == ["Enum", ".map"]
  end
end
```

If `LazyHTML.attribute/2` or `LazyHTML.text/1` have different names in the installed lazy_html, use its equivalents (`LazyHTML.attribute(lazy, name)` returns a list; `LazyHTML.text/1` joins text) and note it in the report.

- [ ] **Step 2: Run to verify failure**

`cd grasp && mix test test/grasp/highlight_test.exs` → `Grasp.Highlight` undefined.

- [ ] **Step 3: Implement**

`grasp/lib/grasp/highlight.ex`:

```elixir
defmodule Grasp.Highlight do
  @moduledoc """
  Renders a function record as syntax-highlighted HTML with a clickable span over every
  resolved call.

  Makeup's Elixir lexer produces tokens without positions, so the tokens are walked while
  tracking line and column against the record's source. A call range (from the index,
  `{line, column}` pairs with an exclusive end column, in file coordinates) may start or
  end inside a token and may span lines; token text is therefore split at range
  boundaries and at newlines, and consecutive pieces inside the same range on the same
  line are wrapped together. Output is one `span.line` per source line so the viewer can
  address lines, with Makeup's short CSS classes on tokens.
  """

  alias Makeup.Lexers.ElixirLexer
  alias Makeup.Token.Utils

  @type opts :: [card_id: pos_integer(), open_targets: [String.t()], external?: (String.t() -> boolean())]

  @doc "Highlighted HTML for `record` with clickable call spans; see the moduledoc."
  @spec render(map(), opts()) :: Phoenix.HTML.safe()
  def render(record, opts) do
    card_id = Keyword.fetch!(opts, :card_id)
    open = MapSet.new(Keyword.get(opts, :open_targets, []))
    external? = Keyword.get(opts, :external?, fn _ -> false end)
    first_line = record["span"]["start_line"]

    ranges =
      for call <- record["calls"], %{"start" => [sl, sc], "end" => [el, ec]} = call["range"] do
        %{target: call["target"], start: {sl, sc}, end: {el, ec}}
      end

    pieces = record["source"] |> ElixirLexer.lex() |> pieces(first_line)

    html =
      pieces
      |> Enum.group_by(& &1.line)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {line, line_pieces} ->
        body = line_pieces |> Enum.flat_map(&split_at_ranges(&1, ranges)) |> wrap_calls(ranges, card_id, open, external?)
        ~s(<span class="line" data-line="#{line}"><span class="ln">#{line}</span>#{body}</span>)
      end)

    {:safe, html}
  end

  # One piece per token per line: %{line, col, text, css}; col is the 1-based start column.
  defp pieces(tokens, first_line) do
    {pieces, _pos} =
      Enum.reduce(tokens, {[], {first_line, 1}}, fn {type, _meta, value}, {acc, {line, col}} ->
        css = Utils.css_class_for_token_type(type)
        text = IO.chardata_to_string(value)
        segments = String.split(text, "\n")
        last = length(segments) - 1

        {acc, pos} =
          segments
          |> Enum.with_index()
          |> Enum.reduce({acc, {line, col}}, fn {segment, i}, {acc, {line, col}} ->
            acc = if segment == "", do: acc, else: [%{line: line, col: col, text: segment, css: css} | acc]
            if i < last, do: {acc, {line + 1, 1}}, else: {acc, {line, col + String.length(segment)}}
          end)

        {acc, pos}
      end)

    Enum.reverse(pieces)
  end

  defp split_at_ranges(piece, ranges) do
    piece_end = piece.col + String.length(piece.text)

    cuts =
      ranges
      |> Enum.flat_map(fn range -> [line_bound(range, piece.line, :start), line_bound(range, piece.line, :end)] end)
      |> Enum.filter(&(&1 > piece.col and &1 < piece_end))
      |> Enum.uniq()
      |> Enum.sort()

    {pieces, _} =
      Enum.reduce(cuts ++ [piece_end], {[], piece.col}, fn cut, {acc, from} ->
        text = String.slice(piece.text, from - piece.col, cut - from)
        {[%{piece | col: from, text: text} | acc], cut}
      end)

    Enum.reverse(pieces)
  end

  defp wrap_calls(pieces, ranges, card_id, open, external?) do
    pieces
    |> Enum.chunk_by(&covering(&1, ranges))
    |> Enum.map_join(fn [first | _] = chunk ->
      inner = Enum.map_join(chunk, &token_html/1)

      case covering(first, ranges) do
        nil ->
          inner

        %{target: target} ->
          attrs =
            ~s( data-target="#{escape(target)}" data-open="#{MapSet.member?(open, target)}") <>
              ~s( data-external="#{external?.(target)}" phx-click="open_call" phx-value-card="#{card_id}" phx-value-target="#{escape(target)}")

          ~s(<span class="call"#{attrs}>#{inner}</span>)
      end
    end)
  end

  # Whitespace is never part of a callee, so a range that continues onto a new line does
  # not swallow that line's indentation.
  defp covering(piece, ranges) do
    if String.trim(piece.text) == "" do
      nil
    else
      Enum.find(ranges, fn range ->
        piece.col >= line_bound(range, piece.line, :start) and piece.col < line_bound(range, piece.line, :end)
      end)
    end
  end

  # The columns a range occupies on `line`: a range covers whole lines between its start and end.
  defp line_bound(%{start: {sl, sc}, end: {el, ec}}, line, :start), do: if(line == sl, do: sc, else: if(line > sl and line <= el, do: 1, else: :infinity))
  defp line_bound(%{start: {sl, _}, end: {el, ec}}, line, :end), do: if(line == el, do: ec, else: if(line >= sl and line < el, do: :infinity, else: -1))

  defp token_html(%{text: text, css: nil}), do: escape(text)
  defp token_html(%{text: text, css: css}), do: ~s(<span class="#{css}">#{escape(text)}</span>)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
```

Notes for the implementer: `:infinity` and `-1` compare correctly against integers in Elixir's term order for the `>`/`<` checks used here (`integer < :infinity` is true because numbers sort before atoms; `-1` is below any column). Verify `Makeup.Token.Utils.css_class_for_token_type/1` exists in the installed makeup (`mix run -e 'IO.inspect Makeup.Token.Utils.css_class_for_token_type(:name_class)'` → `"nc"`); if the function lives elsewhere, use the equivalent and note it. `Utils.css_class_for_token_type(:whitespace)` may return `nil` or `"w"` — both are handled by `token_html/1`.

- [ ] **Step 4: Run, format, commit**

`cd grasp && mix test test/grasp/highlight_test.exs` → 4 pass; then `mix test` all green.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Add Grasp.Highlight: Makeup HTML with clickable call spans

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Review page — sidebar, card tree, card component, CSS

**Files:**
- Create: `grasp/lib/grasp_web/components/card_components.ex`
- Modify: `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/review_live_test.exs`

**Interfaces:**
- Consumes: `Grasp.IndexStore.get/0`, `subscribe/0`; `Grasp.Session.*`; `Grasp.Index.{fetch_function, callers, modules, functions_in_module}`; `Grasp.Highlight.render/2`.
- Produces LiveView events (all `phx-value-*` arrive as strings): `open_root` (`id`), `open_call` (`card`, `target`), `close_card` (`card`), `focus_card` (`card`), `toggle_collapse` (`card`), `open_caller` (`card`, `caller`), `expand_module` (`module`), `move_focus` (`dir`). DOM contract used by tests and later tasks: card root `#card-<id>` with `data-function-id`, `data-focused="true|false"`, `data-depth`; children container `#card-<id>-children`; `.card__close`, `.card__collapse`, `.card__callers` (a `<details>` with `button.caller` items carrying `phx-value-caller`), `.card__also` list for hidden calls; sidebar `#modules` with `button.module` (`phx-value-module`) and `button.fn` (`phx-value-id`); a `.stub` card for ids not in the index.
- Produces `GraspWeb.CardComponents.editor_url(editor, root, file, line) :: String.t() | nil` and `hexdocs_url(function_id) :: String.t() | nil`.

- [ ] **Step 1: LiveView tests**

Replace `grasp/test/grasp_web/live/review_live_test.exs`:

```elixir
defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @shout "SampleApp.Formatter.shout/1"
  @greet_all "SampleApp.Greeter.greet_all/1"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "renders the module list and expands a module into its functions", %{view: view} do
    assert has_element?(view, "#modules button.module", "SampleApp.Greeter")
    refute has_element?(view, "#modules button.fn", "greet/2")

    view |> element("#modules button.module", "SampleApp.Greeter") |> render_click()
    assert has_element?(view, "#modules button.fn", "greet/2")
  end

  test "opening a function from the sidebar adds a focused root card with highlighted source", %{view: view} do
    view |> element("#modules button.module", "SampleApp.Greeter") |> render_click()
    view |> element("#modules button.fn[phx-value-id='#{@greet}']") |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@greet}'][data-focused='true'][data-depth='0']")
    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}']", "Formatter.wrap")
    assert has_element?(view, "#card-1 .card__file", "lib/sample_app/greeter.ex:6")
  end

  test "clicking a call opens the callee as a child; clicking again focuses it", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    assert has_element?(view, "#card-1-children #card-2[data-function-id='#{@wrap}'][data-depth='1'][data-focused='true']")
    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-open='true']")

    view |> element("#card-1 span.call[data-target='#{@shout}']") |> render_click()
    assert has_element?(view, "#card-1-children #card-3[data-function-id='#{@shout}']")
    assert has_element?(view, "#card-2[data-focused='false']")

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    assert has_element?(view, "#card-2[data-focused='true']")
    refute has_element?(view, "#card-4")
  end

  test "closing a card removes its subtree; collapsing hides it behind a count", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.open_child(name, 1, @shout)

    view |> element("#card-1 .card__collapse") |> render_click()
    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "2")

    view |> element("#card-1 .card__collapse") |> render_click()
    assert has_element?(view, "#card-2")

    view |> element("#card-2 .card__close") |> render_click()
    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-3")

    view |> element("#card-1 .card__close") |> render_click()
    refute has_element?(view, "#card-1")
    refute has_element?(view, "#card-3")
  end

  test "opening a caller from a root re-parents the tree", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view |> element("#card-1 .card__callers button.caller[phx-value-caller='#{@greet_all}']") |> render_click()
    assert has_element?(view, "#card-2[data-function-id='#{@greet_all}'][data-depth='0'][data-focused='true']")
    assert has_element?(view, "#card-2-children #card-1[data-depth='1']")
  end

  test "an external call opens a stub card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view |> element("#card-1 span.call[data-target='Enum.map/2'][data-external='true']") |> render_click()
    assert has_element?(view, "#card-2.stub", "Enum.map/2")
    assert has_element?(view, "#card-2.stub a[href='https://hexdocs.pm/elixir/Enum.html#map/2']")
  end

  test "hidden calls are listed under the card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)
    assert has_element?(view, "#card-1 .card__also", @shout)
  end

  test "changes made through the session API render live", %{view: view, name: name} do
    Session.open_root(name, @greet)
    assert has_element?(view, "#card-1")
    Session.close(name, 1)
    refute has_element?(view, "#card-1")
  end

  test "keyboard focus moves through the tree", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.focus(name, 2)

    render_hook(view, "move_focus", %{"dir" => "parent"})
    assert has_element?(view, "#card-1[data-focused='true']")
    render_hook(view, "move_focus", %{"dir" => "child"})
    assert has_element?(view, "#card-2[data-focused='true']")
  end
end
```

The fixture's `greet/2` span starts at line 6 (the `@doc` line) — confirm against `test/fixtures/index.json` (`.functions[] | select(.id=="SampleApp.Greeter.greet/2").span`); adjust the `:6` assertion if the fixture says otherwise.

- [ ] **Step 2: Run to verify failure**

`cd grasp && mix test test/grasp_web/live/review_live_test.exs` → failures on missing elements.

- [ ] **Step 3: Card components**

`grasp/lib/grasp_web/components/card_components.ex`:

```elixir
defmodule GraspWeb.CardComponents do
  @moduledoc """
  The card tree: a recursive node component laying out a card and its children, the card
  itself, and the stub shown for a function the index does not contain.
  """

  use GraspWeb, :html

  alias Grasp.Index
  alias Grasp.Session.Forest

  @stdlib_apps [:elixir, :logger, :eex, :ex_unit, :mix, :iex]

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card_id, :integer, required: true
  attr :editor, :string, default: nil

  def card_node(assigns) do
    card = Forest.card(assigns.forest, assigns.card_id)
    assigns = assign(assigns, card: card, depth: Forest.depth(assigns.forest, assigns.card_id))

    ~H"""
    <div class="node">
      <.card forest={@forest} index={@index} card={@card} depth={@depth} editor={@editor} />
      <div :if={@card.children != [] and not @card.collapsed} class="node__children" id={"card-#{@card.id}-children"}>
        <.card_node :for={child <- @card.children} forest={@forest} index={@index} card_id={child} editor={@editor} />
      </div>
    </div>
    """
  end

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card, :map, required: true
  attr :depth, :integer, required: true
  attr :editor, :string, default: nil

  def card(assigns) do
    case Index.fetch_function(assigns.index, assigns.card.function_id) do
      {:ok, record} -> function_card(assign(assigns, record: record))
      :error -> stub_card(assigns)
    end
  end

  defp function_card(assigns) do
    %{forest: forest, index: index, card: card, record: record} = assigns
    open_targets = for child <- card.children, c = Forest.card(forest, child), do: c.opened_by
    external? = fn target -> match?(:error, Index.fetch_function(index, target)) end

    assigns =
      assign(assigns,
        focused?: forest.focus == card.id,
        callers: Index.callers(index, record["id"]),
        subtree: Forest.subtree_size(forest, card.id),
        body: Grasp.Highlight.render(record, card_id: card.id, open_targets: open_targets, external?: external?),
        editor_href: editor_url(assigns.editor, index.project["root"], record["file"], record["span"]["start_line"])
      )

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={["card", @focused? && "card--focused"]}
      data-function-id={@record["id"]}
      data-focused={to_string(@focused?)}
      data-depth={@depth}
      phx-click="focus_card"
      phx-value-card={@card.id}
    >
      <header class="card__header">
        <h2 class="card__title">
          <span class="card__module">{@record["module"]}.</span><span class="card__fn">{@record["name"]}/{@record["arity"]}</span>
          <span class="card__kind">{@record["kind"]}</span>
        </h2>
        <div class="card__tools">
          <a :if={@editor_href} class="card__file" href={@editor_href}>{@record["file"]}:{@record["span"]["start_line"]}</a>
          <span :if={!@editor_href} class="card__file">{@record["file"]}:{@record["span"]["start_line"]}</span>
          <details :if={@callers != []} class="card__callers">
            <summary>callers ({length(@callers)})</summary>
            <ul>
              <li :for={caller <- @callers}>
                <button class="caller" phx-click="open_caller" phx-value-card={@card.id} phx-value-caller={caller}>{caller}</button>
              </li>
            </ul>
          </details>
          <button :if={@card.children != []} class="card__collapse" phx-click="toggle_collapse" phx-value-card={@card.id} title="Collapse subtree">
            {if @card.collapsed, do: "▸ #{@subtree}", else: "▾"}
          </button>
          <button class="card__close" phx-click="close_card" phx-value-card={@card.id} title="Close (x)">×</button>
        </div>
      </header>
      <pre class="card__body hl">{@body}</pre>
      <footer :if={@record["hidden_calls"] != []} class="card__also">
        <span class="card__also-label">Also calls</span>
        <button :for={call <- @record["hidden_calls"]} class="also" phx-click="open_call" phx-value-card={@card.id} phx-value-target={call["target"]}>
          {call["target"]}
        </button>
      </footer>
    </article>
    """
  end

  defp stub_card(assigns) do
    assigns = assign(assigns, focused?: assigns.forest.focus == assigns.card.id, docs: hexdocs_url(assigns.card.function_id))

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={["card", "stub", @focused? && "card--focused"]}
      data-function-id={@card.function_id}
      data-focused={to_string(@focused?)}
      data-depth={@depth}
      phx-click="focus_card"
      phx-value-card={@card.id}
    >
      <header class="card__header">
        <h2 class="card__title">{@card.function_id}</h2>
        <button class="card__close" phx-click="close_card" phx-value-card={@card.id}>×</button>
      </header>
      <p class="stub__text">Not in the index (a dependency or the standard library).</p>
      <a :if={@docs} class="stub__docs" href={@docs} target="_blank" rel="noopener">Open on hexdocs</a>
    </article>
    """
  end

  @doc "Editor deep link for `file:line` under `root`, or nil when no editor is configured."
  @spec editor_url(String.t() | nil, String.t() | nil, String.t(), pos_integer()) :: String.t() | nil
  def editor_url(nil, _root, _file, _line), do: nil
  def editor_url(_editor, nil, _file, _line), do: nil

  def editor_url(editor, root, file, line) do
    path = Path.join(root, file)

    case editor do
      "vscode" -> "vscode://file/#{path}:#{line}"
      "cursor" -> "cursor://file/#{path}:#{line}"
      "zed" -> "zed://file/#{path}:#{line}"
      "idea" -> "idea://open?file=#{URI.encode(path)}&line=#{line}"
      _ -> nil
    end
  end

  @doc "hexdocs URL for a standard-library function id, or nil for anything else."
  @spec hexdocs_url(String.t()) :: String.t() | nil
  def hexdocs_url(function_id) do
    with [_, module, name, arity] <- Regex.run(~r/^([A-Z][\w.]*)\.([^.\/]+)\/(\d+)$/, function_id),
         mod = Module.concat([module]),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         {:ok, app} when app in @stdlib_apps <- :application.get_application(mod) do
      "https://hexdocs.pm/#{app}/#{module}.html##{name}/#{arity}"
    else
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: The LiveView**

Replace `grasp/lib/grasp_web/live/review_live.ex`:

```elixir
defmodule GraspWeb.ReviewLive do
  @moduledoc """
  The review page: a sidebar of modules and their functions, the card canvas, and the
  palette (Task 6). State is the session's forest plus the loaded index; both arrive by
  PubSub so any change — from this browser, another tab, or an MCP client later — renders
  everywhere.
  """

  use GraspWeb, :live_view

  import GraspWeb.CardComponents

  alias Grasp.{Index, IndexStore, Session}
  alias Grasp.Session.Forest

  @impl true
  def mount(params, _session, socket) do
    name = Map.get(params, "name", "default")
    :ok = Session.ensure(name)

    if connected?(socket) do
      :ok = Session.subscribe(name)
      :ok = IndexStore.subscribe()
    end

    {:ok,
     assign(socket,
       name: name,
       index: IndexStore.get(),
       forest: Session.get(name),
       expanded_module: nil,
       editor: Application.get_env(:grasp, :editor)
     )}
  end

  @impl true
  def handle_info({:session, name, %Forest{} = forest}, %{assigns: %{name: name}} = socket) do
    {:noreply, socket |> assign(forest: forest) |> push_event("focus", %{id: forest.focus})}
  end

  def handle_info(:index_reloaded, socket), do: {:noreply, assign(socket, index: IndexStore.get())}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("expand_module", %{"module" => module}, socket) do
    expanded = if socket.assigns.expanded_module == module, do: nil, else: module
    {:noreply, assign(socket, expanded_module: expanded)}
  end

  def handle_event("open_root", %{"id" => id}, socket), do: mutate(socket, &Session.open_root(&1, id))

  def handle_event("open_call", %{"card" => card, "target" => target}, socket),
    do: mutate(socket, &Session.open_child(&1, int(card), target))

  def handle_event("open_caller", %{"card" => card, "caller" => caller}, socket),
    do: mutate(socket, &Session.open_caller(&1, int(card), caller))

  def handle_event("close_card", %{"card" => card}, socket), do: mutate(socket, &Session.close(&1, int(card)))
  def handle_event("focus_card", %{"card" => card}, socket), do: mutate(socket, &Session.focus(&1, int(card)))
  def handle_event("toggle_collapse", %{"card" => card}, socket), do: mutate(socket, &Session.toggle_collapse(&1, int(card)))

  def handle_event("move_focus", %{"dir" => dir}, socket) when dir in ~w(parent child next prev),
    do: mutate(socket, &Session.move_focus(&1, String.to_existing_atom(dir)))

  def handle_event("close_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close(&1, id))
    end
  end

  def handle_event("collapse_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.toggle_collapse(&1, id))
    end
  end

  # The session broadcasts the new forest to every subscriber including this process, so
  # the returned forest is assigned here only to make the change visible before the
  # broadcast arrives (which matters in tests, where the view may not be connected).
  defp mutate(socket, fun) do
    {:noreply, assign(socket, forest: fun.(socket.assigns.name))}
  end

  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(value) when is_integer(value), do: value

  @impl true
  def render(%{index: nil} = assigns) do
    ~H"""
    <main class="app app--empty">
      <h1 class="brand">Grasp</h1>
      <p class="empty">No index loaded. Start with <code>mix grasp.serve --index path/to/.grasp/index.json</code>.</p>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="app" id="app" phx-hook="Keys">
      <aside class="sidebar">
        <h1 class="brand">Grasp</h1>
        <p class="sidebar__project">{@index.project["app"]}</p>
        <nav id="modules" class="modules">
          <div :for={module <- Index.modules(@index)} class="module-group">
            <button class={["module", @expanded_module == module["name"] && "module--open"]} phx-click="expand_module" phx-value-module={module["name"]}>
              {module["name"]}
            </button>
            <ul :if={@expanded_module == module["name"]} class="fns">
              <li :for={fun <- Index.functions_in_module(@index, module["name"])}>
                <button class={["fn", "fn--#{fun["kind"]}"]} phx-click="open_root" phx-value-id={fun["id"]}>
                  {fun["name"]}/{fun["arity"]}
                </button>
              </li>
            </ul>
          </div>
        </nav>
      </aside>
      <section class="canvas" id="canvas">
        <p :if={@forest.roots == []} class="empty">Pick a function from the sidebar or press <kbd>⌘K</kbd>.</p>
        <div class="roots">
          <.card_node :for={root <- @forest.roots} forest={@forest} index={@index} card_id={root} editor={@editor} />
        </div>
      </section>
    </main>
    """
  end
end
```

- [ ] **Step 5: CSS for the tree**

Append to `grasp/assets/css/app.css`:

```css
.app--empty { grid-template-columns: 1fr; }
.empty { color: var(--fg-muted); padding: var(--space-l); }
kbd { font-family: var(--mono); background: var(--bg-raised); border: 1px solid var(--border); border-radius: 4px; padding: 0 0.3em; }

.sidebar { border-right: 1px solid var(--border); background: var(--bg-sunken); overflow-y: auto; }
.sidebar__project { margin: 0 var(--space-m) var(--space-s); color: var(--fg-muted); font-family: var(--mono); }
.modules { display: flex; flex-direction: column; padding-bottom: var(--space-l); }
.module { display: block; width: 100%; text-align: start; padding: var(--space-xs) var(--space-m); font-family: var(--mono); font-size: 0.85rem; color: var(--fg-muted); }
.module:hover, .module--open { color: var(--fg); background: var(--bg-raised); }
.fns { list-style: none; margin: 0; padding: 0 0 var(--space-xs) var(--space-l); }
.fn { display: block; width: 100%; text-align: start; padding: 2px var(--space-s); font-family: var(--mono); font-size: 0.85rem; }
.fn:hover { color: var(--accent); }
.fn--defp { color: var(--fg-muted); }

.canvas { overflow: auto; padding: var(--space-m); }
.roots { display: flex; flex-direction: column; gap: var(--space-l); align-items: flex-start; }

.node { display: flex; flex-direction: row; align-items: flex-start; gap: var(--space-l); }
.node__children { display: flex; flex-direction: column; gap: var(--space-m); position: relative; }
.node__children::before { content: ""; position: absolute; inset-inline-start: calc(-1 * var(--space-l) / 2); inset-block: var(--space-m); border-inline-start: 1px solid var(--border); }
.node__children > .node > .card::before { content: ""; position: absolute; inset-inline-start: calc(-1 * var(--space-l) / 2); top: var(--space-m); width: calc(var(--space-l) / 2); border-top: 1px solid var(--border); }

.card { position: relative; width: var(--card-width); flex: none; background: var(--bg-raised); border: 1px solid var(--border); border-radius: var(--radius); font-family: var(--mono); font-size: 0.85rem; }
.card--focused { border-color: var(--focus); box-shadow: 0 0 0 1px var(--focus); }
.card__header { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: var(--space-s); padding: var(--space-s) var(--space-m); border-bottom: 1px solid var(--border); }
.card__title { margin: 0; font-size: 0.9rem; font-weight: 600; }
.card__module { color: var(--fg-muted); font-weight: 400; }
.card__kind { margin-inline-start: var(--space-s); color: var(--fg-muted); font-weight: 400; font-size: 0.75rem; }
.card__tools { display: flex; align-items: center; gap: var(--space-s); color: var(--fg-muted); font-size: 0.75rem; }
.card__file { color: var(--fg-muted); text-decoration: none; }
.card__file:hover { color: var(--accent); }
.card__callers summary { cursor: pointer; list-style: none; }
.card__callers ul { position: absolute; z-index: 2; margin: var(--space-xs) 0 0; padding: var(--space-xs); list-style: none; background: var(--bg-sunken); border: 1px solid var(--border); border-radius: var(--radius); max-height: 16rem; overflow: auto; }
.caller { display: block; width: 100%; text-align: start; padding: 2px var(--space-s); white-space: nowrap; }
.caller:hover { color: var(--accent); }
.card__collapse, .card__close { padding: 0 var(--space-xs); color: var(--fg-muted); }
.card__close:hover { color: var(--danger); }
.card__body { margin: 0; padding: var(--space-s) 0; overflow-x: auto; line-height: 1.45; background: transparent !important; }
.line { display: block; padding-inline: var(--space-m); white-space: pre; }
.ln { display: inline-block; width: 3ch; margin-inline-end: var(--space-m); text-align: end; color: var(--fg-muted); user-select: none; }
.call { cursor: pointer; border-bottom: 1px dashed var(--accent); }
.call:hover { background: var(--accent-soft); }
.call[data-open="true"] { background: var(--accent-soft); border-bottom-style: solid; }
.call[data-external="true"] { border-bottom-color: var(--fg-muted); opacity: 0.8; }
.card__also { display: flex; flex-wrap: wrap; gap: var(--space-xs); padding: var(--space-s) var(--space-m); border-top: 1px solid var(--border); font-size: 0.75rem; }
.card__also-label { color: var(--fg-muted); }
.also { color: var(--accent); }
.stub .card__header { border-bottom: 0; }
.stub__text, .stub__docs { margin: 0 var(--space-m) var(--space-s); display: block; color: var(--fg-muted); }
.stub__docs { color: var(--accent); }
```

- [ ] **Step 6: Run the tests**

`cd grasp && mix test test/grasp_web/live/review_live_test.exs` → 9 tests. Common failures and what they mean: `has_element?` on `data-focused` — the session's returned forest must be assigned synchronously in `mutate/2`; `.card__file` line — compare with the fixture span; `stub a[href=...]` — `hexdocs_url/1` requires `Enum` to be loaded in the test VM (it is). Then `mix test` all green and `mix assets.build` succeeds.

- [ ] **Step 7: Format and commit**

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Render the review page: module sidebar and the branching card tree

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Command palette and keyboard hooks

**Files:**
- Create: `grasp/lib/grasp_web/components/palette.ex`, `grasp/assets/js/hooks/palette.js`, `grasp/assets/js/hooks/keys.js`
- Modify: `grasp/lib/grasp_web/live/review_live.ex` (palette assigns/events, render the component), `grasp/assets/js/app.js` (register hooks), `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/palette_test.exs`

**Interfaces:**
- LiveView events: `palette_search` (`%{"q" => query}`), `palette_open` (`%{"id" => function_id, "child" => boolean}`); server pushes `palette:close` after opening. DOM: `dialog#palette` with `form#palette-form input[name=q]`, results `ul#palette-results > li[data-id] > button.palette__item[phx-click=palette_open]`, `aria-selected` on the first result by default.
- Keys hook events (already handled in Task 5): `move_focus` (`dir`), `close_focused`, `collapse_focused`; server push `focus` (`%{id}`) scrolls `#card-<id>` into view.

- [ ] **Step 1: Tests**

`grasp/test/grasp_web/live/palette_test.exs`:

```elixir
defmodule GraspWeb.PaletteTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "typing searches the index and ranks results", %{view: view} do
    view |> form("#palette-form", %{q: "greet"}) |> render_change()

    assert has_element?(view, "#palette-results li[data-id='SampleApp.Greeter.greet/2'] button", "SampleApp.Greeter.greet/2")
    assert has_element?(view, "#palette-results li[data-id='SampleApp.Greeter.greet_all/1']")
    refute has_element?(view, "#palette-results li[data-id='SampleApp.Formatter.wrap/1']")
    assert has_element?(view, "#palette-results li:first-child[aria-selected='true']")
  end

  test "an empty query shows no results", %{view: view} do
    view |> form("#palette-form", %{q: "  "}) |> render_change()
    refute has_element?(view, "#palette-results li")
  end

  test "palette_open opens a root and closes the dialog", %{view: view} do
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => false})

    assert has_element?(view, "#card-1[data-function-id='SampleApp.Formatter.wrap/1'][data-depth='0']")
    assert_push_event(view, "palette:close", %{})
  end

  test "palette_open with child: true opens under the focused card", %{view: view, name: name} do
    Session.open_root(name, "SampleApp.Greeter.greet/2")
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => true})

    assert has_element?(view, "#card-1-children #card-2[data-function-id='SampleApp.Formatter.wrap/1']")
  end

  test "palette_open with child: true and no focus opens a root", %{view: view} do
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => true})
    assert has_element?(view, "#card-1[data-depth='0']")
  end
end
```

- [ ] **Step 2: Run to verify failure**

`cd grasp && mix test test/grasp_web/live/palette_test.exs` → failures (no form/elements).

- [ ] **Step 3: Palette component**

`grasp/lib/grasp_web/components/palette.ex`:

```elixir
defmodule GraspWeb.Palette do
  @moduledoc """
  The Cmd+K function palette: a `<dialog>` with a search input and ranked results. The
  `Palette` JS hook opens it, moves the selection with the arrow keys and reports the
  choice with `palette_open`; the server searches on every change and closes the dialog
  after opening a card.
  """

  use GraspWeb, :html

  attr :query, :string, required: true
  attr :results, :list, required: true

  def palette(assigns) do
    ~H"""
    <dialog id="palette" class="palette" phx-hook="Palette">
      <form id="palette-form" phx-change="palette_search" phx-submit="palette_submit" autocomplete="off">
        <input type="text" name="q" value={@query} placeholder="Type a function name… (Enter opens, Shift+Enter opens under the focused card)" phx-debounce="80" autofocus />
      </form>
      <ul id="palette-results" class="palette__results">
        <li :for={{fun, i} <- Enum.with_index(@results)} data-id={fun["id"]} aria-selected={to_string(i == 0)}>
          <button type="button" class="palette__item" phx-click="palette_open" phx-value-id={fun["id"]} phx-value-child="false">
            <span class="palette__id">{fun["id"]}</span>
            <span class="palette__meta">{fun["kind"]} · {fun["file"]}</span>
          </button>
        </li>
      </ul>
    </dialog>
    """
  end
end
```

- [ ] **Step 4: Wire the LiveView**

In `GraspWeb.ReviewLive`: `import GraspWeb.Palette`; add `palette_query: "", palette_results: []` to the mount assigns; render `<.palette query={@palette_query} results={@palette_results} />` as the last child of `<main class="app" ...>` (the non-empty `render/1`); add events:

```elixir
  def handle_event("palette_search", %{"q" => query}, socket) do
    results = Index.search(socket.assigns.index, query, 20)
    {:noreply, assign(socket, palette_query: query, palette_results: results)}
  end

  def handle_event("palette_submit", _params, socket) do
    case socket.assigns.palette_results do
      [first | _] -> open_from_palette(socket, first["id"], false)
      [] -> {:noreply, socket}
    end
  end

  def handle_event("palette_open", %{"id" => id} = params, socket) do
    child? = params["child"] in [true, "true"]
    open_from_palette(socket, id, child?)
  end

  defp open_from_palette(socket, id, child?) do
    name = socket.assigns.name

    forest =
      case {child?, socket.assigns.forest.focus} do
        {true, focus} when is_integer(focus) -> Session.open_child(name, focus, id)
        _ -> Session.open_root(name, id)
      end

    {:noreply,
     socket
     |> assign(forest: forest, palette_query: "", palette_results: [])
     |> push_event("palette:close", %{})}
  end
```

Update the moduledoc's "(Task 6)" mention to describe the palette as present.

- [ ] **Step 5: JS hooks**

`grasp/assets/js/hooks/palette.js`:

```js
const Palette = {
  mounted() {
    this.dialog = this.el
    this.input = this.el.querySelector("input[name=q]")
    this.results = this.el.querySelector("#palette-results")

    this.onKeydownWindow = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.open()
      }
    }
    window.addEventListener("keydown", this.onKeydownWindow)

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        this.move(e.key === "ArrowDown" ? 1 : -1)
      } else if (e.key === "Enter") {
        e.preventDefault()
        const selected = this.results.querySelector("li[aria-selected='true']")
        if (selected) this.pushEvent("palette_open", {id: selected.dataset.id, child: e.shiftKey})
      }
    })

    this.el.addEventListener("click", (e) => {
      if (e.target === this.dialog) this.dialog.close()
    })

    this.handleEvent("palette:close", () => this.dialog.close())
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydownWindow)
  },

  open() {
    if (!this.dialog.open) this.dialog.showModal()
    this.input.value = ""
    this.input.focus()
  },

  move(delta) {
    const items = Array.from(this.results.querySelectorAll("li"))
    if (items.length === 0) return
    const current = items.findIndex((li) => li.getAttribute("aria-selected") === "true")
    const next = Math.min(items.length - 1, Math.max(0, current + delta))
    items.forEach((li, i) => li.setAttribute("aria-selected", String(i === next)))
    items[next].scrollIntoView({block: "nearest"})
  },
}

export default Palette
```

`grasp/assets/js/hooks/keys.js`:

```js
const DIRECTIONS = {ArrowLeft: "parent", ArrowRight: "child", ArrowUp: "prev", ArrowDown: "next"}

const Keys = {
  mounted() {
    this.onKeydown = (e) => {
      const inField = ["INPUT", "TEXTAREA"].includes(e.target.tagName) || document.getElementById("palette")?.open
      if (inField || e.metaKey || e.ctrlKey || e.altKey) return

      if (DIRECTIONS[e.key]) {
        e.preventDefault()
        this.pushEvent("move_focus", {dir: DIRECTIONS[e.key]})
      } else if (e.key === "x") {
        this.pushEvent("close_focused", {})
      } else if (e.key === "c") {
        this.pushEvent("collapse_focused", {})
      }
    }
    window.addEventListener("keydown", this.onKeydown)

    this.handleEvent("focus", ({id}) => {
      if (id == null) return
      const card = document.getElementById(`card-${id}`)
      card?.scrollIntoView({block: "nearest", inline: "nearest", behavior: "smooth"})
    })
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
}

export default Keys
```

In `grasp/assets/js/app.js`, import both and register `hooks: {Palette, Keys}`.

Append to `app.css`:

```css
.palette { width: min(48rem, 90vw); padding: 0; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-raised); color: var(--fg); }
.palette::backdrop { background: color-mix(in oklch, black 60%, transparent); }
.palette input { width: 100%; padding: var(--space-m); font: inherit; font-family: var(--mono); color: var(--fg); background: var(--bg-sunken); border: 0; border-bottom: 1px solid var(--border); outline: none; }
.palette__results { list-style: none; margin: 0; padding: var(--space-xs) 0; max-height: 50vh; overflow: auto; }
.palette__item { display: flex; justify-content: space-between; gap: var(--space-m); width: 100%; padding: var(--space-xs) var(--space-m); text-align: start; font-family: var(--mono); }
.palette__results li[aria-selected="true"] .palette__item { background: var(--accent-soft); }
.palette__meta { color: var(--fg-muted); font-size: 0.75rem; white-space: nowrap; }
```

- [ ] **Step 6: Run, build, format, commit**

`cd grasp && mix test` → all green; `mix assets.build` bundles without errors.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Add the Cmd+K palette and keyboard navigation hooks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `mix grasp.serve` and a real run

**Files:**
- Create: `grasp/lib/mix/tasks/grasp.serve.ex`
- Modify: `grasp/README.md` (already documents the command; verify wording), root `README.md` (add the two-command quick start)

**Interfaces:**
- Produces: `mix grasp.serve --index PATH [--port N] [--editor vscode|cursor|zed|idea]`. Sets `GRASP_INDEX`, `GRASP_PORT`, `GRASP_EDITOR` for `config/runtime.exs`, enables endpoint serving, and runs the app with `--no-halt`.

- [ ] **Step 1: The task**

`grasp/lib/mix/tasks/grasp.serve.ex`:

```elixir
defmodule Mix.Tasks.Grasp.Serve do
  @shortdoc "Serves the Grasp viewer for an index file"

  @moduledoc """
  Starts the Grasp viewer.

      mix grasp.serve --index PATH [--port 4040] [--editor vscode]

  The index is the file `mix grasp.index` wrote in the target project. The viewer binds
  to 127.0.0.1 and reloads the index whenever the file changes.

  ## Options

    * `--index` - path to the index JSON (or set `GRASP_INDEX`). Required.
    * `--port` - HTTP port, default 4040.
    * `--editor` - `vscode`, `cursor`, `zed` or `idea`; turns `file:line` into a deep link.
  """

  use Mix.Task

  @switches [index: :string, port: :integer, editor: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.serve: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    index = opts[:index] || System.get_env("GRASP_INDEX") || Mix.raise("grasp.serve: --index PATH is required")
    index = Path.expand(index)

    unless File.regular?(index), do: Mix.raise("grasp.serve: no such file #{index}")

    System.put_env("GRASP_INDEX", index)
    if opts[:port], do: System.put_env("GRASP_PORT", Integer.to_string(opts[:port]))
    if opts[:editor], do: System.put_env("GRASP_EDITOR", opts[:editor])

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.shell().info("Grasp viewer: http://127.0.0.1:#{opts[:port] || 4040}  (index: #{index})")
    Mix.Task.run("run", ["--no-halt"])
  end
end
```

- [ ] **Step 2: Try it on the fixture**

From `grasp/`: `mix grasp.serve --index test/fixtures/index.json --port 4042 &` then `sleep 8 && curl -s http://127.0.0.1:4042/ | grep -c "SampleApp"` → at least 1; `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4042/assets/app.js` → 200; then kill the background job. The dev watcher runs esbuild in watch mode; if the esbuild binary is not installed yet the first start downloads it.

- [ ] **Step 3: Try it on a real index**

If a real project's `.grasp/index.json` exists on this machine (the controller will say where), run `mix grasp.serve --index <that path>` and load `http://127.0.0.1:4040/` in a headless check: `curl -s http://127.0.0.1:4040/ | grep -o 'class="module"' | wc -l` should be in the hundreds. Do not write that project's name or path into any tracked file. Record startup time and any warnings in the report.

- [ ] **Step 4: Root README quick start**

Add to the root `README.md`, after "Layout":

```markdown
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
```

- [ ] **Step 5: Format, full suite, commit**

`cd grasp && mix format && mix compile --warnings-as-errors && mix test` → green.

```bash
cd ~/repos/grasp && git add -A && git commit -m "Add mix grasp.serve and the quick start

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage (Part 2, minus deferred milestones).** Index in `:persistent_term` with mtime reload → Task 2. Session GenServer per name with PubSub → Task 3 (forest only; annotations/tour/persistence deferred to M5/M6 as the spec's milestone list says). Card tree semantics (child open, focus existing, close subtree, collapse, caller re-parent, palette root/child) → Tasks 3 and 5. Pure-CSS layout with fixed card width and connectors → Task 5. Page with sidebar (modules stand in for entry points until M3), canvas, keyboard → Tasks 5 and 6. Card header/body/footer, external stub with hexdocs link, editor links → Task 5. Highlighting with clickable ranges (no ETS cache: computed per render) → Task 4. Palette → Task 6. Assets: esbuild, hand-written CSS → Tasks 1, 5, 6. `mix grasp.serve --index --port --editor` → Task 7.
- **Type consistency.** Card ids are integers in `Forest` and in `Session`; the LiveView converts `phx-value-card` strings with `int/1`; `Highlight.render/2` receives `card_id` as an integer and prints it. `open_targets` is built from children's `opened_by`, which `Forest.open_child/3` sets to the function id. `Index.functions_in_module/2` is added in Task 2 before Task 5 uses it. Test DOM contract (`#card-N`, `#card-N-children`, `data-*`, class names) is identical in Task 5's component and its tests and reused by Task 6's tests.
- **Known soft spots.** (1) `Session.mutate/2` handles both `{forest, id}` and `forest` returns; `Session.open_*` callers discard the id — the LiveView never needs it because focus follows the new card. (2) `hexdocs_url/1` depends on the viewer VM having the module loaded; only stdlib apps qualify, so dependency modules get no link (spec: stub card "linking to hexdocs" is satisfied for the stdlib, which is the common case for external calls). (3) The Keys hook uses `window` listeners; a second LiveView on the page would double-handle — not a case this app has.
