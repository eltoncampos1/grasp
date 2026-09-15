# Grasp Entry Points (Milestone 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The index records a project's entry points — Phoenix routes to controller actions and LiveViews, Oban workers, LiveView/LiveComponent callbacks, GenServer/Supervisor/Application/Plug callbacks — and the viewer's sidebar starts from them; cards show which entry points they are.

**Architecture:** `Grasp.Index.EntryPoints` runs inside the target's Mix session after the traced compile, introspecting compiled modules: routers by an exported `__routes__/0` (`Phoenix.Router.routes/1`), the rest by `@behaviour` attributes or `__live__/0`. Every candidate callback is emitted only if the index has a definition for it, which is what separates a user-written `handle_info/2` from the default `use GenServer` injects. Module behaviours fill `modules[].behaviours`. `Grasp.Index` gains `entry_points_for/2`. The viewer's sidebar becomes collapsible groups (Routes, Oban workers, LiveViews, GenServers, OTP, Plugs, Modules); cards show entry badges. (The per-function highlight cache shipped in milestone 2.1.)

**Tech Stack:** as before. The indexer fixture `sample_app` gains phoenix, phoenix_live_view, plug and oban as deps (no database, nothing started).

**Spec:** `docs/specs/2026-09-15-grasp-design.md` Part 1 step 4 (entry points), Part 2 "Page" (sidebar). Amendments in Task 5: routers detected by `__routes__/0`, callbacks filtered by indexed definitions, route meta has no pipelines (Phoenix 1.8 `routes/1` does not expose them).

## Global Constraints

- `grasp_index` must not gain compile-time dependencies on Phoenix, LiveView or Oban: call them through `apply/3` guarded by `Code.ensure_loaded?/1`, never as direct remote calls.
- Entry point record: `%{"kind", "label", "target", "meta"}`; kinds: `route`, `live_route`, `oban_worker`, `live_view`, `live_component`, `genserver`, `supervisor`, `application`, `plug`. `target` is a function id present in the index (canonical id or an alias arity).
- Sorted deterministically: by kind order above, then label, then target.
- Conventions as in earlier plans (`@moduledoc`, `@doc`+`@spec`, HEEx rules, tokens only, `mix format`, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, no third-party project names).

---

### Task 1: Grow the indexer fixture app

**Files (all under `grasp_index/test/fixtures/sample_app/`):**
- Modify: `mix.exs`
- Create: `lib/sample_app_web/router.ex`, `lib/sample_app_web/endpoint.ex`, `lib/sample_app_web/greet_controller.ex`, `lib/sample_app_web/hello_live.ex`, `lib/sample_app_web/request_id.ex`, `lib/sample_app/workers/mailer.ex`, `lib/sample_app/counter.ex`, `lib/sample_app/application.ex`, `config/config.exs`

- [ ] **Step 1: deps**

```elixir
      deps: [
        {:grasp_index, path: "../../..", only: :dev, runtime: false},
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.2"},
        {:oban, "~> 2.19"}
      ]
```

and `application/0` stays without `mod:` (nothing starts). Add `config/config.exs`:

```elixir
import Config
config :sample_app, SampleAppWeb.Endpoint, secret_key_base: String.duplicate("s", 64), render_errors: [formats: [html: SampleAppWeb.ErrorHTML]]
```

(`ErrorHTML` is not needed for compilation — remove the `render_errors` key if the endpoint compiles without it; keep the config minimal.)

- [ ] **Step 2: modules**

`lib/sample_app_web/endpoint.ex`:

```elixir
defmodule SampleAppWeb.Endpoint do
  @moduledoc "Minimal endpoint so the router compiles."
  use Phoenix.Endpoint, otp_app: :sample_app
  plug SampleAppWeb.Router
end
```

`lib/sample_app_web/router.ex`:

```elixir
defmodule SampleAppWeb.Router do
  @moduledoc "Routes exercised by the entry-point detector."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", SampleAppWeb do
    pipe_through :browser
    get "/greet/:name", GreetController, :show
    post "/greet", GreetController, :create
    live "/hello", HelloLive
  end
end
```

`lib/sample_app_web/greet_controller.ex`:

```elixir
defmodule SampleAppWeb.GreetController do
  @moduledoc "Controller actions that call into the greeter."
  use Phoenix.Controller, formats: [:html]

  @doc "Greets the named person."
  def show(conn, %{"name" => name}), do: text(conn, SampleApp.Greeter.greet(name))

  @doc "Greets loudly."
  def create(conn, %{"name" => name}), do: text(conn, SampleApp.Greeter.greet(name, true))
end
```

`lib/sample_app_web/hello_live.ex`:

```elixir
defmodule SampleAppWeb.HelloLive do
  @moduledoc "A LiveView with three callbacks."
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, name: "world")}

  def handle_event("rename", %{"name" => name}, socket), do: {:noreply, assign(socket, name: name)}

  def render(assigns) do
    ~H"""
    <p>{SampleApp.Greeter.greet(@name)}</p>
    """
  end
end
```

`lib/sample_app_web/request_id.ex`:

```elixir
defmodule SampleAppWeb.RequestId do
  @moduledoc "A plain plug."
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts), do: Plug.Conn.put_resp_header(conn, "x-request-id", "1")
end
```

`lib/sample_app/workers/mailer.ex`:

```elixir
defmodule SampleApp.Workers.Mailer do
  @moduledoc "An Oban worker."
  use Oban.Worker, queue: :mail, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"name" => name}}), do: {:ok, SampleApp.Greeter.greet(name)}
end
```

`lib/sample_app/counter.ex`:

```elixir
defmodule SampleApp.Counter do
  @moduledoc "A GenServer defining two callbacks; the rest are use GenServer defaults."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, 0, opts)

  @impl true
  def init(count), do: {:ok, count}

  @impl true
  def handle_call(:next, _from, count), do: {:reply, count + 1, count + 1}
end
```

`lib/sample_app/application.ex`:

```elixir
defmodule SampleApp.Application do
  @moduledoc "Application module (not started by the fixture)."
  use Application

  @impl true
  def start(_type, _args), do: Supervisor.start_link([SampleApp.Counter], strategy: :one_for_one)
end
```

- [ ] **Step 3: compile the fixture and confirm the existing indexer suite is green**

`cd grasp_index/test/fixtures/sample_app && mix deps.get && MIX_ENV=dev mix compile` (Oban pulls ecto/ecto_sql/postgrex — compile only; no database is touched). Then `cd grasp_index && mix test --include integration` → the existing integration assertions still hold (function counts change — update `builder_test.exs` counts if any assertion pins them; the greeter file is unchanged so its ranges hold). Commit the fixture's `mix.lock`.

```bash
cd ~/repos/grasp && git add -A && git commit -m "Grow the indexer fixture with a router, LiveView, Oban worker, GenServer and plug

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Entry-point detection in the indexer

**Files:**
- Create: `grasp_index/lib/grasp/index/entry_points.ex`
- Modify: `grasp_index/lib/grasp/index/builder.ex`
- Test: `grasp_index/test/grasp/index/builder_test.exs` (integration assertions), `grasp_index/test/grasp/index/entry_points_test.exs` (unit)

**Interfaces:**
- `Grasp.Index.EntryPoints.detect(app :: atom(), indexed :: MapSet.t(String.t())) :: %{entry_points: [entry()], behaviours: %{String.t() => [String.t()]}}` with `entry() :: %{kind: String.t(), label: String.t(), target: String.t(), meta: map()}` (meta values are strings/integers, string keys).
- Builder passes `indexed = MapSet.new(for f <- functions, a <- f.arities, do: Join.function_id(f.module, f.name, a))`; writes `"entry_points"` and `modules[].behaviours`.

- [ ] **Step 1: Integration assertions (RED)**

Add to `builder_test.exs`:

```elixir
  test "records entry points", %{index: index} do
    entries = Grasp.Index.entry_points(index)
    by_kind = Enum.group_by(entries, & &1["kind"])

    assert %{"label" => "GET /greet/:name", "target" => "SampleAppWeb.GreetController.show/2", "meta" => %{"verb" => "GET", "path" => "/greet/:name", "router" => "SampleAppWeb.Router"}} = find(entries, "SampleAppWeb.GreetController.show/2")
    assert find(entries, "SampleAppWeb.GreetController.create/2")["label"] == "POST /greet"
    assert %{"kind" => "live_route", "label" => "GET /hello", "target" => "SampleAppWeb.HelloLive.mount/3"} = Enum.find(entries, &(&1["kind"] == "live_route"))

    assert %{"meta" => %{"queue" => "mail", "max_attempts" => 5}} = find(entries, "SampleApp.Workers.Mailer.perform/1")

    live_targets = by_kind["live_view"] |> Enum.map(& &1["target"]) |> Enum.sort()
    assert live_targets == ["SampleAppWeb.HelloLive.handle_event/3", "SampleAppWeb.HelloLive.mount/3", "SampleAppWeb.HelloLive.render/1"]

    genserver_targets = by_kind["genserver"] |> Enum.map(& &1["target"]) |> Enum.sort()
    assert genserver_targets == ["SampleApp.Counter.handle_call/3", "SampleApp.Counter.init/1"]

    assert [%{"target" => "SampleApp.Application.start/2"}] = by_kind["application"]
    assert [%{"target" => "SampleAppWeb.RequestId.call/2"}] = by_kind["plug"]
    refute Enum.any?(entries, &String.starts_with?(&1["target"], "SampleAppWeb.GreetController.call/"))
    refute Enum.any?(entries, &String.starts_with?(&1["target"], "SampleAppWeb.Endpoint."))
    assert entries == Enum.sort_by(entries, &{kind_rank(&1["kind"]), &1["label"], &1["target"]})
  end

  test "records module behaviours", %{index: index} do
    mods = Map.new(Grasp.Index.modules(index), &{&1["name"], &1["behaviours"]})
    assert "Oban.Worker" in mods["SampleApp.Workers.Mailer"]
    assert "GenServer" in mods["SampleApp.Counter"]
    assert mods["SampleApp.Formatter"] == []
  end

  defp find(entries, target), do: Enum.find(entries, &(&1["target"] == target))
  defp kind_rank(kind), do: Enum.find_index(~w(route live_route oban_worker live_view live_component genserver supervisor application plug), &(&1 == kind))
```

Whether `SampleAppWeb.Endpoint` shows up as a `plug` depends on whether `use Phoenix.Endpoint` declares `@behaviour Plug` — it does, and the endpoint's `call/2` is macro-generated (no definition in the index), so the indexed-definition filter excludes it. The `refute` pins that.

- [ ] **Step 2: Implement**

`grasp_index/lib/grasp/index/entry_points.ex`:

```elixir
defmodule Grasp.Index.EntryPoints do
  @moduledoc """
  Finds the places a project's code starts executing: routes, workers, LiveView and OTP
  callbacks, plugs.

  Runs inside the target's Mix session after compilation, so compiled modules can be
  introspected. Routers are found by their exported `__routes__/0` (`use Phoenix.Router`
  declares no behaviour); everything else by `@behaviour` attributes or `__live__/0`.
  A callback becomes an entry point only when the index holds a definition for it:
  `use GenServer` injects default `handle_call/3` and friends that `function_exported?/3`
  reports as present, and those are noise. Phoenix, LiveView and Oban are reached through
  `apply/3` so this package never depends on them at compile time.
  """

  alias Grasp.Index.Join

  @type entry :: %{kind: String.t(), label: String.t(), target: String.t(), meta: map()}

  @kinds ~w(route live_route oban_worker live_view live_component genserver supervisor application plug)
  @live_callbacks [mount: 3, handle_params: 3, handle_event: 3, handle_info: 2, handle_async: 3, render: 1]
  @component_callbacks [update: 2, handle_event: 3, render: 1]
  @genserver_callbacks [init: 1, handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2, terminate: 2]

  @doc "Entry points and per-module behaviours for `app`, keeping only targets in `indexed`."
  @spec detect(atom(), MapSet.t(String.t())) :: %{entry_points: [entry()], behaviours: %{String.t() => [String.t()]}}
  def detect(app, indexed) do
    Application.load(app)
    {:ok, modules} = :application.get_key(app, :modules)
    Enum.each(modules, &Code.ensure_loaded/1)

    behaviours = Map.new(modules, &{inspect(&1), &1 |> behaviours_of() |> Enum.map(&inspect/1) |> Enum.sort()})
    routes = modules |> Enum.filter(&function_exported?(&1, :__routes__, 0)) |> Enum.flat_map(&routes(&1, indexed))
    controllers = MapSet.new(routes, &module_of(&1.target))
    callbacks = Enum.flat_map(modules, &module_entries(&1, indexed, controllers))

    %{entry_points: Enum.sort_by(routes ++ callbacks, &{rank(&1.kind), &1.label, &1.target}), behaviours: behaviours}
  end

  defp routes(router, indexed) do
    if Code.ensure_loaded?(Phoenix.Router) do
      for route <- apply(Phoenix.Router, :routes, [router]),
          route.verb != :*,
          is_atom(route.plug_opts),
          {kind, target} <- List.wrap(route_target(route, indexed)) do
        %{
          kind: kind,
          label: "#{route.verb |> Atom.to_string() |> String.upcase()} #{route.path}",
          target: target,
          meta: %{"verb" => route.verb |> Atom.to_string() |> String.upcase(), "path" => route.path, "router" => inspect(router), "helper" => route.helper}
        }
      end
    else
      []
    end
  end

  defp route_target(%{plug: Phoenix.LiveView.Plug, metadata: %{phoenix_live_view: {view, _action, _opts, _session}}}, indexed) do
    keep({"live_route", Join.function_id(view, :mount, 3)}, indexed)
  end

  defp route_target(%{plug: Phoenix.LiveView.Plug}, _indexed), do: nil
  defp route_target(%{plug: controller, plug_opts: action}, indexed), do: keep({"route", Join.function_id(controller, action, 2)}, indexed)

  defp module_entries(mod, indexed, controllers) do
    bs = behaviours_of(mod)
    live? = Phoenix.LiveView in bs or function_exported?(mod, :__live__, 0)

    List.flatten([
      if(Oban.Worker in bs, do: entries("oban_worker", mod, [perform: 1], indexed, oban_meta(mod)), else: []),
      if(live?, do: entries("live_view", mod, @live_callbacks, indexed, %{}), else: []),
      if(Phoenix.LiveComponent in bs, do: entries("live_component", mod, @component_callbacks, indexed, %{}), else: []),
      if(GenServer in bs, do: entries("genserver", mod, @genserver_callbacks, indexed, %{}), else: []),
      if(Supervisor in bs, do: entries("supervisor", mod, [init: 1], indexed, %{}), else: []),
      if(Application in bs, do: entries("application", mod, [start: 2], indexed, %{}), else: []),
      if(Plug in bs and not MapSet.member?(controllers, inspect(mod)), do: entries("plug", mod, [call: 2], indexed, %{}), else: [])
    ])
  end

  defp entries(kind, mod, callbacks, indexed, meta) do
    for {fun, arity} <- callbacks,
        id = Join.function_id(mod, fun, arity),
        MapSet.member?(indexed, id) do
      %{kind: kind, label: id, target: id, meta: meta}
    end
  end

  defp keep({_kind, target} = entry, indexed), do: if(MapSet.member?(indexed, target), do: entry)

  defp oban_meta(mod) do
    if function_exported?(mod, :__opts__, 0) do
      opts = apply(mod, :__opts__, [])
      %{"queue" => to_string(Keyword.get(opts, :queue, "default")), "max_attempts" => Keyword.get(opts, :max_attempts)}
    else
      %{}
    end
  end

  defp behaviours_of(mod) do
    mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  rescue
    _ -> []
  end

  defp module_of(function_id), do: function_id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
  defp rank(kind), do: Enum.find_index(@kinds, &(&1 == kind))
end
```

`module_of/1` must handle ids like `":erlang.max/2"` (no dots before the name) — it never receives those (targets are controllers), but keep it total.

Builder: after `functions = Join.join(...)`:

```elixir
    indexed = MapSet.new(for f <- functions, a <- f.arities, do: Join.function_id(f.module, f.name, a))
    %{entry_points: entry_points, behaviours: behaviours} = EntryPoints.detect(config[:app], indexed)
```

`module_json/1` takes `behaviours` (`Map.get(behaviours, name, [])`), `"entry_points" => Enum.map(entry_points, &%{"kind" => &1.kind, "label" => &1.label, "target" => &1.target, "meta" => &1.meta})`. Update the moduledoc paragraph that said milestone 3 fills behaviours.

Unit test `entry_points_test.exs`: define, in the test file, small modules exercising the filter without Phoenix: a module with `@behaviour GenServer` defining `init/1` and `handle_call/3` and one with `use GenServer` defining only `init/1`; `detect/2` needs an app — instead expose a `@doc false` `module_entries/3`? Keep unit tests to `behaviours_of`-driven behaviour via `detect(:grasp_index, indexed)` is wrong (the app is grasp_index itself). Ruling: rely on the integration test for `detect/2`; add one unit test for the sort order using a tiny `@doc false def sort(entries)` if helpful — otherwise skip the unit file.

- [ ] **Step 3: GREEN, format, commit**

`cd grasp_index && mix test --include integration` → green. `mix format`. Commit: `Detect entry points and module behaviours in the indexer`.

---

### Task 3: Reader support and the viewer fixture

**Files:**
- Modify: `grasp_index/lib/grasp/index.ex`, `grasp_index/test/grasp/index_test.exs`, `grasp/test/fixtures/index.json`

- [ ] **Step 1:** `Grasp.Index.entry_points_for(index, function_id) :: [map()]` — built at load as `%{canonical_target => [entries]}` (resolve alias arities), sorted like the document. Test with a document carrying two entries for one target and one alias-arity target.

- [ ] **Step 2:** Regenerate `grasp/test/fixtures/index.json` from the grown fixture (`MIX_ENV=dev mix grasp.index --out ../../../../grasp/test/fixtures/index.json` in `sample_app`), then re-apply the hand edits: `project.root` `/tmp/sample_app`, `git` null, pinned `generated_at`, the hidden call on `greet_all/1`. Run the viewer suite; fix any assertion that pinned function counts. Commit: `Read entry points per function; refresh the viewer fixture`.

---

### Task 4: Sidebar groups and card badges

**Files:**
- Create: `grasp/lib/grasp_web/components/sidebar.ex`
- Modify: `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/card_components.ex`, `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/review_live_test.exs`

- [ ] **Step 1: Tests**

```elixir
  test "the sidebar lists entry points by kind and opens their target", %{view: view} do
    assert has_element?(view, "#entries .group[data-kind='routes'] .group__title", "Routes")
    assert has_element?(view, "#entries .group[data-kind='routes'] button.entry[phx-value-id='SampleAppWeb.GreetController.show/2']", "GET /greet/:name")
    refute has_element?(view, "#entries .group[data-kind='oban'] button.entry")

    view |> element("#entries .group[data-kind='oban'] .group__title") |> render_click()
    assert has_element?(view, "#entries .group[data-kind='oban'] button.entry", "SampleApp.Workers.Mailer.perform/1")

    view |> element("#entries button.entry[phx-value-id='SampleAppWeb.GreetController.show/2']") |> render_click()
    assert has_element?(view, "#card-1[data-function-id='SampleAppWeb.GreetController.show/2']")
    assert has_element?(view, "#card-1 .badge", "GET /greet/:name")
  end
```

Groups (`data-kind`): `routes` (route + live_route, expanded by default), `oban`, `live` (live_view + live_component), `genservers`, `otp` (supervisor + application), `plugs`, `modules` (the existing module list, collapsed by default). Group title buttons toggle `expanded_groups` (a MapSet assign, initial `MapSet.new(["routes"])`), event `toggle_group` (`group`).

- [ ] **Step 2: Implement** `GraspWeb.Sidebar.entry_groups/1` (attrs `index`, `expanded`, `expanded_module`) rendering `nav#entries` with one `.group` per kind that has entries (plus `modules` always); route items show label with a `title` of the router; callback items show the id. Card header gets `<span :for={e <- entry_points_for(...)} class={["badge", "badge--#{e["kind"]}"]}>{e["label"]}</span>` before the title. CSS: `.group__title` full-width button with count and a chevron via `data-open`; `.badge` small, `--accent-soft` background, `border-radius: 999px`.

- [ ] **Step 3:** green, format, commit: `Sidebar starts from entry points; cards show entry badges`.

---

### Task 5: Spec, README, real run

- Spec Part 1 step 4: routers by `__routes__/0`; callbacks kept only when indexed; route meta `verb/path/router/helper` (no pipelines); LiveComponent kind; `live_route` kind. Part 2 "Page": sidebar groups. Milestone list: mark 1–3 done. Known gaps: pipelines unavailable; LiveViews routed only via `live/2` (not `live_session` metadata differences — verify on the real run).
- READMEs: mention entry points.
- Real run: re-index the controller-named project (`mix grasp.index` there), start the viewer on a spare port, `curl` the page and count `.group` elements; record route/worker counts in the private report; kill the server. Never name the project in tracked files.
- Commit: `Document entry-point detection`.

## Self-review

- Detection is behaviour/export based and callback presence is checked against the index, so `use GenServer` defaults, macro-generated `call/2` on endpoints/controllers, and dependency controllers (forwarded routers) are excluded without special cases.
- `Join.function_id/3` is the single id formatter; `indexed` includes alias arities so a controller action with a default argument still matches.
- The viewer fixture is regenerated once (Task 3) after the indexer changes, so Task 4 tests against real entry data.
