# Grasp MCP and Chat Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An MCP server at `/mcp` through which an agent reads the index and arranges cards with highlights, and a chat panel in the viewer that runs the Claude Code CLI against that server so "show me the award bonus flow" arranges the cards on screen.

**Architecture:** `anubis_mcp` serves Streamable HTTP on the existing Phoenix endpoint; tool modules are thin adapters over `Grasp.Index`, `Grasp.Session` and a new pure path finder `Grasp.Paths`. The forest gains a `highlight` per card and a whole-forest replace. `Grasp.Agent.Runner` is a GenServer per session that spawns the CLI as an Erlang port, parses its JSON stream through the pure `Grasp.Agent.Stream`, and broadcasts a transcript that `ReviewLive` renders in a dock; card changes reach the browser through the ordinary session broadcast because the agent goes through MCP like any other client.

**Tech Stack:** Elixir 1.19+, Phoenix 1.8 / LiveView 1.2, anubis_mcp ~> 2.0, Erlang ports, esbuild-bundled JS hooks (no new JS libraries).

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 3 (MCP, Chat panel), Part 2 §Session/§Card, Milestones (4).

## Global Constraints

- The grasp repo is public. Never name any real target project, company or private path in code, tests, docs or commit messages; fixtures are `SampleApp`.
- All work happens in `grasp/` (the viewer). `grasp_index/` is untouched in this milestone.
- Every public function has `@doc` and `@spec`; every module has `@moduledoc`; HEEx function components document inputs with `attr`/`slot` and carry no `@spec`.
- UI state is server-owned (LiveView patches strip client-set attributes); client-only state lives in a hook's own fields, `phx-update="ignore"` elements or body classes.
- Tools return JSON text content via `Anubis.Server.Response.json/2`; domain failures are `Response.error/2` (the model can react); a missing index is a `Response.error` "no index loaded".
- Anubis reference source for the implementer: a checkout of the anubis_mcp repository (`pages/building-a-server.md`, `pages/transports.md`, `pages/testing.md`, `lib/anubis/server/component.ex`, `lib/anubis/server/response.ex`). Read them before guessing an API.
- Tests are `async: true`; session and agent names are `"t-#{System.unique_integer([:positive])}"`.
- `mix format` before each commit; `mix test` green; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Existing test count is 91; nothing may be deleted or weakened to pass.

---

### Task 1: Forest highlights, replace and JSON shape

**Files:**
- Modify: `grasp/lib/grasp/session/forest.ex`
- Modify: `grasp/lib/grasp/session.ex`
- Test: `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs`

**Interfaces:**
- Consumes: the existing `Forest` (`open_root/2`, `open_child/4`, `card/2`, `close/2`) and `Session` (`mutate`, broadcast `{:session, name, forest}`).
- Produces:
  - card gains `highlight: nil | %{"call" => String.t()} | %{"lines" => [integer(), integer()]}`; `add_card` sets `highlight: nil`.
  - `Forest.set_highlight(t(), id(), highlight()) :: t()` — no-op on unknown id.
  - `Forest.replace([spec()]) :: {:ok, t()} | {:error, {:unknown_parent, String.t()}}` where `spec :: %{key: String.t(), function_id: String.t(), parent_key: String.t() | nil, opened_by: String.t() | nil, highlight: highlight()}`. Entries apply in order; a `parent_key` must name an earlier entry; focus is the first root; a duplicate `key` overwrites the mapping (last wins) and is not an error.
  - `Forest.to_map(t()) :: map()` — `%{"roots" => [id], "focus" => id | nil, "cards" => [%{"id","function_id","parent_id","children","opened_by","collapsed","highlight"}]}` with cards sorted by id.
  - `Session.set_cards(name, [spec()]) :: {:ok, Forest.t()} | {:error, term()}` — broadcasts only on success.
  - `Session.set_highlight(name, id, highlight) :: Forest.t()`.
  - `Session.list() :: [String.t()]` — names of running sessions, sorted.
  - `Session.open_child/4` unchanged; `close/2` drops the highlight with the card (nothing to do, it lives on the card).

- [ ] **Step 1: Failing tests**

`forest_test.exs` (append inside the existing module):

```elixir
  describe "highlights" do
    test "set_highlight stores a call or a line range and ignores unknown ids" do
      {forest, id} = Forest.open_root(Forest.new(), "A.f/1")
      forest = Forest.set_highlight(forest, id, %{"call" => "B.g/0"})
      assert Forest.card(forest, id).highlight == %{"call" => "B.g/0"}
      forest = Forest.set_highlight(forest, id, %{"lines" => [3, 5]})
      assert Forest.card(forest, id).highlight == %{"lines" => [3, 5]}
      assert Forest.set_highlight(forest, 999, nil) == forest
    end

    test "a new card has no highlight" do
      {forest, id} = Forest.open_root(Forest.new(), "A.f/1")
      assert Forest.card(forest, id).highlight == nil
    end
  end

  describe "replace/1" do
    test "builds the forest in order, linking children to parents by key" do
      spec = [
        %{key: "a", function_id: "A.f/1", parent_key: nil, opened_by: nil, highlight: nil},
        %{key: "b", function_id: "B.g/0", parent_key: "a", opened_by: "B.g/0", highlight: %{"lines" => [1, 2]}},
        %{key: "c", function_id: "C.h/0", parent_key: "a", opened_by: nil, highlight: nil},
        %{key: "d", function_id: "D.i/0", parent_key: nil, opened_by: nil, highlight: nil}
      ]

      assert {:ok, forest} = Forest.replace(spec)
      assert forest.roots == [1, 4]
      assert forest.focus == 1
      assert Forest.card(forest, 1).children == [2, 3]
      assert Forest.card(forest, 2).parent_id == 1
      assert Forest.card(forest, 2).opened_by == "B.g/0"
      assert Forest.card(forest, 2).highlight == %{"lines" => [1, 2]}
      assert Forest.card(forest, 3).opened_by == "C.h/0"
      assert Forest.card(forest, 4).parent_id == nil
    end

    test "an unknown parent key is an error" do
      spec = [%{key: "b", function_id: "B.g/0", parent_key: "zzz", opened_by: nil, highlight: nil}]
      assert Forest.replace(spec) == {:error, {:unknown_parent, "zzz"}}
    end

    test "an empty spec is an empty forest" do
      assert {:ok, %Forest{roots: [], cards: %{}, focus: nil}} = Forest.replace([])
    end
  end

  test "to_map/1 is the JSON shape with cards sorted by id" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    forest = Forest.set_highlight(forest, b, %{"call" => "C.h/0"})

    assert Forest.to_map(forest) == %{
             "roots" => [a],
             "focus" => b,
             "cards" => [
               %{"id" => a, "function_id" => "A.f/1", "parent_id" => nil, "children" => [b],
                 "opened_by" => nil, "collapsed" => false, "highlight" => nil},
               %{"id" => b, "function_id" => "B.g/0", "parent_id" => a, "children" => [],
                 "opened_by" => "B.g/0", "collapsed" => false, "highlight" => %{"call" => "C.h/0"}}
             ]
           }
  end
```

`session_test.exs` (append):

```elixir
  test "set_cards replaces the forest and broadcasts once; an error leaves it untouched", %{name: name} do
    Session.subscribe(name)
    Session.open_root(name, "Old.f/0")
    assert_receive {:session, ^name, _}

    spec = [%{key: "a", function_id: "A.f/1", parent_key: nil, opened_by: nil, highlight: nil}]
    assert {:ok, forest} = Session.set_cards(name, spec)
    assert [%{function_id: "A.f/1"}] = Map.values(forest.cards)
    assert_receive {:session, ^name, ^forest}

    bad = [%{key: "b", function_id: "B.g/0", parent_key: "nope", opened_by: nil, highlight: nil}]
    assert {:error, {:unknown_parent, "nope"}} = Session.set_cards(name, bad)
    refute_receive {:session, ^name, _}, 50
    assert Session.get(name) == forest
  end

  test "set_highlight broadcasts the highlighted forest", %{name: name} do
    Session.subscribe(name)
    %{roots: [id]} = Session.open_root(name, "A.f/1")
    forest = Session.set_highlight(name, id, %{"lines" => [2, 3]})
    assert Forest.card(forest, id).highlight == %{"lines" => [2, 3]}
    assert_receive {:session, ^name, ^forest}
  end

  test "list/0 names the running sessions", %{name: name} do
    assert name in Session.list()
  end
```

Match the `setup` the existing `session_test.exs` uses (it creates and ensures a unique `name`); if it does not alias `Forest`, add `alias Grasp.Session.Forest`.

- [ ] **Step 2: Run to see them fail**

`cd grasp && mix test test/grasp/session` — failures on undefined `set_highlight/3`, `replace/1`, `to_map/1`, `set_cards/2`, `list/0`.

- [ ] **Step 3: Implement**

In `forest.ex`: add `highlight: nil` to `add_card`'s card map and to the `card` type (`@type highlight :: nil | %{String.t() => term()}` is acceptable; prefer the precise union). Then:

```elixir
  @doc "Sets `highlight` on `id`; unknown ids are ignored."
  @spec set_highlight(t(), id(), highlight()) :: t()
  def set_highlight(%__MODULE__{} = forest, id, highlight) do
    case card(forest, id) do
      nil -> forest
      card -> %{forest | cards: Map.put(forest.cards, id, %{card | highlight: highlight})}
    end
  end

  @doc """
  Builds a forest from an ordered flat spec. A `parent_key` names an earlier entry; the
  first entry with no parent becomes the focus.
  """
  @spec replace([spec()]) :: {:ok, t()} | {:error, {:unknown_parent, String.t()}}
  def replace(specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, new(), %{}}, fn spec, {:ok, forest, keys} ->
      case spec.parent_key do
        nil ->
          {forest, id} = open_root(forest, spec.function_id)
          {:cont, {:ok, highlight(forest, id, spec), Map.put(keys, spec.key, id)}}

        parent_key ->
          case Map.fetch(keys, parent_key) do
            {:ok, parent_id} ->
              {forest, id} = add_child(forest, parent_id, spec.function_id, spec.opened_by || spec.function_id)
              {:cont, {:ok, highlight(forest, id, spec), Map.put(keys, spec.key, id)}}

            :error ->
              {:halt, {:error, {:unknown_parent, parent_key}}}
          end
      end
    end)
    |> case do
      {:ok, forest, _keys} -> {:ok, %{forest | focus: List.first(forest.roots)}}
      {:error, _} = error -> error
    end
  end
```

`add_child/4` is the "true" branch of `open_child/4` extracted (it must *always* add, even when a sibling shows the same function, because a spec may legitimately repeat a function under one parent); have `open_child/4` call it so the logic exists once. `highlight/3` is a private `set_highlight(forest, id, spec.highlight)`.

`to_map/1`:

```elixir
  @doc "The forest as plain maps with string keys, the shape the MCP tools return."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = forest) do
    cards =
      forest.cards
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn card ->
        %{
          "id" => card.id, "function_id" => card.function_id, "parent_id" => card.parent_id,
          "children" => card.children, "opened_by" => card.opened_by,
          "collapsed" => card.collapsed, "highlight" => card.highlight
        }
      end)

    %{"roots" => forest.roots, "focus" => forest.focus, "cards" => cards}
  end
```

In `session.ex`: `set_cards/2` sends `{:replace, specs}`; the handler calls `Forest.replace/1`, broadcasts and stores only on `{:ok, forest}`, replies with the tuple either way. `set_highlight/3` goes through `mutate`. `list/0`:

```elixir
  @doc "Names of the sessions currently running, sorted."
  @spec list() :: [String.t()]
  def list do
    Registry.select(Grasp.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end
```

- [ ] **Step 4: Run, format, commit**

`mix test` green (91 + new). `mix format`. Commit: `Forest: highlights, replace and a JSON shape`.

---

### Task 2: Highlights render on the card

**Files:**
- Modify: `grasp/lib/grasp/highlight.ex`
- Modify: `grasp/lib/grasp_web/components/card_components.ex`
- Modify: `grasp/assets/css/app.css`
- Modify: `grasp/assets/js/hooks/canvas.js`
- Test: `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`

**Interfaces:**
- Consumes: `card.highlight` from Task 1; `Highlight.render(record, opts)` with `card_id`, `open_targets`, `external?`.
- Produces: `Highlight.render/2` accepts `highlight: nil | %{"call" => target} | %{"lines" => [a, b]}`. A `.call` whose raw `target` equals the highlighted call renders `data-highlight="true"`; a `.line` whose number is within `a..b` renders `data-highlight="true"`. The card component passes `highlight: @card.highlight`. `revealCard` in the Canvas hook pans to the first `[data-highlight="true"]` inside the card when there is one, otherwise to the card as today.

- [ ] **Step 1: Failing tests**

`highlight_test.exs` (the module's `@record` has `SampleApp.Greeter.greet/2`-style calls; use its real call target — read the file for the exact target string in `@record["calls"]` and put it where `CALL_TARGET` stands):

```elixir
  test "a highlighted call carries data-highlight and the others do not" do
    html = render(highlight: %{"call" => CALL_TARGET})
    assert LazyHTML.query(html, ~s(.call[data-highlight="true"])) |> Enum.count() == 1
    assert LazyHTML.query(html, ~s(.call[data-highlight="true"])) |> LazyHTML.attribute("data-target") == [CALL_TARGET]
  end

  test "highlighted lines carry data-highlight over the range only" do
    html = render(highlight: %{"lines" => [11, 12]})
    assert LazyHTML.query(html, ~s(.line[data-highlight="true"])) |> LazyHTML.attribute("data-line") == ~w(11 12)
  end

  test "no highlight, no attribute" do
    html = render()
    assert LazyHTML.query(html, "[data-highlight]") |> Enum.count() == 0
  end
```

(`@record`'s span starts at line 10 per the existing tests; if not, pick two numbers inside its span.)

`review_live_test.exs`:

```elixir
  test "a highlighted card renders the ring and the tinted lines", %{view: view, name: name} do
    %{roots: [id]} = Session.open_root(name, @greet)
    Session.set_highlight(name, id, %{"call" => @wrap})
    assert has_element?(view, ~s(#card-#{id} .call[data-highlight="true"][data-target="#{@wrap}"]))

    Session.set_highlight(name, id, %{"lines" => [21, 22]})
    assert has_element?(view, ~s(#card-#{id} .line[data-highlight="true"][data-line="21"]))
    refute has_element?(view, ~s(#card-#{id} .call[data-highlight="true"]))
  end
```

If `greet/2`'s span in `test/fixtures/index.json` does not include lines 21–22, read its `span` and use two lines inside it.

- [ ] **Step 2: Run to see them fail**

`mix test test/grasp/highlight_test.exs test/grasp_web/live/review_live_test.exs`.

- [ ] **Step 3: Implement**

`highlight.ex`: add `highlight:` to `@type opts`; read `highlight = Keyword.get(opts, :highlight)`; pass a `hl_call` (string or nil) into `wrap_calls/5` → `/6` and emit ` data-highlight="true"` when `target == hl_call`; in the line loop emit ` data-highlight="true"` on the `.line` span when `match?(%{"lines" => [a, b]} when a <= line and line <= b, highlight)`. Nothing else changes, so the parse cache is unaffected (the cache holds pieces, not HTML).

`card_components.ex`: where `Highlight.render` is called for the body, add `highlight: @card.highlight` (find the call; it already passes `card_id` and `open_targets`).

`app.css` next to the `.call` rules:

```css
.call[data-highlight="true"] { outline: 2px solid var(--accent); outline-offset: 1px; border-radius: 2px; background: var(--accent-soft); }
.line[data-highlight="true"] { background: var(--accent-soft); }
```

`canvas.js` `revealCard(id)`: after finding `card`, `const target = card.querySelector('[data-highlight="true"]') || card` and measure `b = target.getBoundingClientRect()`; keep the existing clamping (a highlighted line is far narrower than the card, so the horizontal clamp still behaves). Keep the "reveal only on a change of focus" guard untouched: a highlight set on the focused card by an agent arrives with the same focus, so also reveal when the card's highlight fingerprint changes — track `this.lastHighlight = card.dataset.highlight` where the card component renders `data-highlight-key={highlight_key(@card.highlight)}` (a short string like `call:B.g/0` or `lines:3-5` or nothing). In the `updated()` path that currently compares `id === this.lastFocus`, compare `${id}:${key}` instead.

- [ ] **Step 4: Run, format, commit**

`mix test`; `mix format`; also `cd grasp && mix assets.build` compiles the JS without error. Commit: `Cards render a highlighted call or line range`.

---

### Task 3: `Grasp.Paths` — shortest call paths

**Files:**
- Create: `grasp/lib/grasp/paths.ex`
- Test: `grasp/test/grasp/paths_test.exs`

**Interfaces:**
- Consumes: `Grasp.Index.callers/2`, `Grasp.Index.callees/2` (both return resolved ids), `Grasp.Index.entry_points/1`, `Grasp.Index.fetch_function/2`.
- Produces:
  - `Grasp.Paths.between(index, from, to, opts) :: result()`
  - `Grasp.Paths.to_entry_points(index, to, opts) :: result()`
  - `result :: %{paths: [[String.t()]], truncated?: boolean()}`; `opts :: [max_depth: pos_integer(), limit: pos_integer(), budget: pos_integer()]`, defaults `max_depth: 6, limit: 5, budget: 20_000`. `max_depth` is hops (a path of n ids has n-1 hops). Paths are listed shortest first, ties by the path's ids ascending. `truncated?` is true when the visit budget ended the walk before the queue drained.

- [ ] **Step 1: Failing tests**

```elixir
defmodule Grasp.PathsTest do
  use ExUnit.Case, async: true

  alias Grasp.Paths

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @create "SampleAppWeb.GreetController.create/2"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @hello_render "SampleAppWeb.HelloLive.render/1"
  @component_render "SampleAppWeb.GreetingComponent.render/1"

  setup_all do
    {:ok, index} = Grasp.Index.load("test/fixtures/index.json")
    %{index: index}
  end

  test "between/4 finds the chain through a default-arity alias", %{index: index} do
    assert %{paths: [[@show, @greet, @wrap]], truncated?: false} =
             Paths.between(index, @show, @wrap, [])
  end

  test "between/4 with no route is empty", %{index: index} do
    assert %{paths: [], truncated?: false} = Paths.between(index, @wrap, @show, [])
  end

  test "to_entry_points/3 walks callers back to every entry point, shortest first", %{index: index} do
    %{paths: paths, truncated?: false} = Paths.to_entry_points(index, @wrap, limit: 10)

    assert paths == [
             [@perform, @greet, @wrap],
             [@create, @greet, @wrap],
             [@show, @greet, @wrap],
             [@component_render, @greet, @wrap],
             [@hello_render, @greet, @wrap]
           ]
  end

  test "limit and max_depth cut the result", %{index: index} do
    assert %{paths: [_, _]} = Paths.to_entry_points(index, @wrap, limit: 2)
    assert %{paths: []} = Paths.to_entry_points(index, @wrap, max_depth: 1)
  end

  test "an exhausted budget is reported", %{index: index} do
    assert %{truncated?: true} = Paths.to_entry_points(index, @wrap, budget: 1)
  end

  test "an unknown function has no paths", %{index: index} do
    assert %{paths: []} = Paths.between(index, "Nope.f/0", @wrap, [])
  end
end
```

All five paths have two hops, so the order is the ids of their entry ends ascending (`Enum.sort/1`); `"SampleApp.Workers"` sorts before `"SampleAppWeb"` because `.` precedes `W`, and `GreetController` before `GreetingComponent` because `C` precedes `i`.

- [ ] **Step 2: Run to see them fail** — `mix test test/grasp/paths_test.exs`.

- [ ] **Step 3: Implement**

```elixir
defmodule Grasp.Paths do
  @moduledoc """
  Shortest call paths over an index, for agents building a tour or explaining a flow.

  Breadth-first over paths: the queue holds whole paths, a `{node, depth}` set stops a node
  from being re-entered at a greater depth while still letting two same-length paths share a
  node, and a visit budget bounds the walk on a large graph. Results are shortest first.
  """

  alias Grasp.Index

  @type result :: %{paths: [[String.t()]], truncated?: boolean()}
  @type opts :: [max_depth: pos_integer(), limit: pos_integer(), budget: pos_integer()]

  @defaults [max_depth: 6, limit: 5, budget: 20_000]

  @doc "Paths from `from` to `to` following callees."
  @spec between(Index.t(), String.t(), String.t(), opts()) :: result()
  def between(%Index{} = index, from, to, opts) do
    to = canonical(index, to)
    search(index, [[canonical(index, from)]], &Index.callees(index, &1), &(&1 == to), Keyword.merge(@defaults, opts))
  end

  @doc "Paths from any entry-point target down to `to`, found by walking callers backwards."
  @spec to_entry_points(Index.t(), String.t(), opts()) :: result()
  def to_entry_points(%Index{} = index, to, opts) do
    entries = index |> Index.entry_points() |> MapSet.new(&canonical(index, &1["target"]))
    result = search(index, [[canonical(index, to)]], &Index.callers(index, &1), &MapSet.member?(entries, &1), Keyword.merge(@defaults, opts))
    %{result | paths: Enum.map(result.paths, &Enum.reverse/1)}
  end
```

`search/5`: queue (`:queue`) of paths whose head is the frontier node; pop; `budget` decrements per pop, when it hits 0 return `truncated?: true`; if `goal?.(head)` and `length(path) > 1 or from == to` collect the path (a path of one node counts only when `from == to`; simpler: never accept the seed itself — document it); stop when `limit` paths are found; do not expand past `max_depth` hops; expand `next.(head)` sorted ascending, skipping nodes already in the path and nodes in `seen` at a smaller depth (`seen` maps node → depth of first visit; allow when equal). Also skip when `Index.fetch_function(index, head) == :error` for the seed (unknown function → empty result). `canonical/2` is `Index.fetch_function/2` → record `"id"`, or the given id when unknown (the reader resolves aliases; `Grasp.Index.callees/2` and `callers/2` already return canonical ids). Sort the collected paths by `{length, path}` before returning.

Expected result ordering in `to_entry_points`: paths are collected reversed (target first) and then reversed; sort **after** reversing so the tie-break uses the entry-point end.

- [ ] **Step 4: Run, format, commit** — `Paths: shortest call paths for agents`.

---

### Task 4: MCP server with the read tools

**Files:**
- Modify: `grasp/mix.exs` (add `{:anubis_mcp, "~> 2.0"}`)
- Create: `grasp/lib/grasp/mcp/server.ex`, `grasp/lib/grasp/mcp/tools.ex` (shared helpers), `grasp/lib/grasp/mcp/tools/search_functions.ex`, `get_function.ex`, `get_callers.ex`, `get_callees.ex`, `find_paths.ex`, `list_entry_points.ex`, `list_modules.ex`, `list_sessions.ex`
- Modify: `grasp/lib/grasp/application.ex`, `grasp/lib/grasp_web/router.ex`
- Test: `grasp/test/grasp/mcp/tools_test.exs` (unit, `execute/2`), `grasp/test/grasp_web/mcp_test.exs` (HTTP integration)

**Interfaces:**
- Consumes: `Grasp.IndexStore.get/0` (index or nil), `Grasp.Index.*`, `Grasp.Paths`, `Grasp.Session.list/0`.
- Produces: server module `Grasp.MCP.Server` (`use Anubis.Server, name: "grasp", version: <mix version>, capabilities: [:tools]`, one `component` line per tool); `Grasp.MCP.Tools.index/0 :: {:ok, Index.t()} | {:error, Response.t()}` and `Grasp.MCP.Tools.reply(frame, data) :: {:reply, Response.t(), frame}` (`Response.json(Response.tool(), data)`); `Grasp.MCP.Tools.error(frame, message)`. Tool names as seen by clients are the snake_case module basenames (`search_functions`, …) — check how Anubis derives the name (`Anubis.Server.Component` docs) and set it explicitly with the `name:` option if the default differs.

Tool contracts (schema → JSON result):

- `search_functions` — `query: string required`, `limit: integer default 20 (max 100)` → `%{"results" => [%{"id","kind","file","line","change"}]}` (`line` is `span.start_line`).
- `get_function` — `id: string required` → the record without `"base_source"` plus `"callers" => [ids]`, `"callees" => [ids]`, `"entry_points" => [%{"kind","label"}]`; unknown id → `Response.error("unknown function: <id>")`.
- `get_callers` / `get_callees` — `id` → `%{"id" => canonical, "callers"|"callees" => [ids]}`; unknown → error.
- `find_paths` — `to: string required`, `from: string optional`, `max_depth: integer default 6 (max 8)`, `limit: integer default 5 (max 20)` → `%{"paths" => [%{"ids" => [...], "entry" => %{"kind","label"} | nil}], "truncated" => bool}`; `entry` is the entry point whose target is the path's first id when one exists (first match from `Index.entry_points_for/2`). Unknown `to`/`from` → error.
- `list_entry_points` — `kind: string optional`, `query: string optional` (case-insensitive substring over label and target), `limit: integer default 100 (max 500)` → `%{"total" => n, "entry_points" => [%{"kind","label","target"}]}`.
- `list_modules` — `query: string optional`, `limit: integer default 200 (max 2000)` → `%{"total", "modules" => [%{"name","file","behaviours"}]}`.
- `list_sessions` — no params → `%{"sessions" => [names]}`.

Every tool: when `IndexStore.get()` is nil, reply `Response.error(Response.tool(), "no index loaded")`.

- [ ] **Step 1: Failing unit tests** — `test/grasp/mcp/tools_test.exs`, one `describe` per tool. Sketch (fill every tool the same way):

```elixir
defmodule Grasp.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.{Frame, Response}
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  test "search_functions ranks and caps" do
    {:reply, resp, _} = Tools.SearchFunctions.execute(%{query: "greet", limit: 2}, %Frame{})
    refute resp.isError
    assert %{"results" => [%{"id" => _, "kind" => _, "file" => _, "line" => _} = first, _]} = json!(resp)
    assert first["id"] =~ "greet"
  end

  test "get_function returns the record, callers, callees and entry points" do
    {:reply, resp, _} = Tools.GetFunction.execute(%{id: "SampleApp.Greeter.greet/1"}, %Frame{})
    body = json!(resp)
    assert body["id"] == @greet
    assert @wrap in body["callees"]
    assert @show in body["callers"]
    refute Map.has_key?(body, "base_source")

    {:reply, resp, _} = Tools.GetFunction.execute(%{id: @show}, %Frame{})
    assert %{"entry_points" => [%{"kind" => "route", "label" => "GET /greet/:name"}]} = json!(resp)
  end

  test "unknown ids are tool errors" do
    {:reply, %Response{isError: true}, _} = Tools.GetFunction.execute(%{id: "Nope.f/0"}, %Frame{})
    {:reply, %Response{isError: true}, _} = Tools.GetCallers.execute(%{id: "Nope.f/0"}, %Frame{})
    {:reply, %Response{isError: true}, _} = Tools.FindPaths.execute(%{to: "Nope.f/0", from: nil, max_depth: 6, limit: 5}, %Frame{})
  end

  test "find_paths annotates entry points" do
    {:reply, resp, _} = Tools.FindPaths.execute(%{to: @wrap, from: nil, max_depth: 6, limit: 10}, %Frame{})
    %{"paths" => paths, "truncated" => false} = json!(resp)
    assert %{"ids" => [@show, @greet, @wrap], "entry" => %{"kind" => "route", "label" => "GET /greet/:name"}} in paths
  end

  test "list_entry_points filters by kind and query" do
    {:reply, resp, _} = Tools.ListEntryPoints.execute(%{kind: "route", query: "greet/:name", limit: 100}, %Frame{})
    assert %{"total" => 1, "entry_points" => [%{"target" => @show}]} = json!(resp)
  end

  test "list_modules and list_sessions" do
    {:reply, resp, _} = Tools.ListModules.execute(%{query: "greeter", limit: 200}, %Frame{})
    assert %{"modules" => [%{"name" => "SampleApp.Greeter"} | _]} = json!(resp)

    name = "t-#{System.unique_integer([:positive])}"
    :ok = Grasp.Session.ensure(name)
    {:reply, resp, _} = Tools.ListSessions.execute(%{}, %Frame{})
    assert name in json!(resp)["sessions"]
  end

  test "every tool's input schema is what clients see" do
    assert "query" in Tools.SearchFunctions.input_schema()["required"]
    assert "to" in Tools.FindPaths.input_schema()["required"]
    refute "from" in (Tools.FindPaths.input_schema()["required"] || [])
  end
end
```

The test env already loads `test/fixtures/index.json` into the store at boot (`config/test.exs`), so `IndexStore.get()` is populated. `execute/2` receives atom keys with defaults filled; pass optional fields as `nil` when absent (that is what the validation layer passes — verify in the Anubis source and adjust the tests to match).

- [ ] **Step 2: Failing integration test** — `test/grasp_web/mcp_test.exs`:

```elixir
defmodule GraspWeb.MCPTest do
  use GraspWeb.ConnCase, async: true

  @greet "SampleApp.Greeter.greet/2"

  test "initialize, list tools, call one", %{conn: conn} do
    {conn, session} = initialize(conn)

    result = rpc(conn, session, "tools/list", %{})
    names = result["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ~w(find_paths get_callees get_callers get_function list_entry_points list_modules list_sessions search_functions)

    result = rpc(conn, session, "tools/call", %{"name" => "get_callees", "arguments" => %{"id" => @greet}})
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"callees" => callees} = Jason.decode!(text)
    assert "SampleApp.Formatter.wrap/1" in callees
  end

  # -- helpers -------------------------------------------------------------

  defp initialize(conn) do
    conn =
      post_json(conn, nil, %{
        "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{},
                      "clientInfo" => %{"name" => "test", "version" => "0"}}
      })

    assert %{"result" => %{"serverInfo" => %{"name" => "grasp"}}} = decode(conn)
    [session] = get_resp_header(conn, "mcp-session-id")
    post_json(conn, session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    {Phoenix.ConnTest.build_conn(), session}
  end

  defp rpc(conn, session, method, params) do
    conn = post_json(conn, session, %{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]), "method" => method, "params" => params})
    assert %{"result" => result} = decode(conn)
    result
  end

  defp post_json(conn, session, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(&if(session, do: put_req_header(&1, "mcp-session-id", session), else: &1))
    |> post("/mcp", Jason.encode!(body))
  end

  # The transport answers a POST either as one JSON document or as an SSE stream holding it.
  defp decode(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      ["text/event-stream" <> _] ->
        conn.resp_body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim() |> Jason.decode!()))
        |> List.last()

      _ ->
        Jason.decode!(conn.resp_body)
    end
  end
end
```

Read `pages/testing.md` in the Anubis source for how its own integration test drives the plug and adjust the helpers (headers, session handling, `notifications/initialized` response code 202) rather than fighting the transport.

- [ ] **Step 3: Implement**

`mix.exs`: add the dep; `mix deps.get`. `application.ex`: add `{Grasp.MCP.Server, transport: {:streamable_http, start: true}}` after `GraspWeb.Endpoint` in `children` (with `start: true` it runs under `mix test` too, which the integration test needs). `router.ex`: outside the `:browser` scope, no pipeline:

```elixir
  forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: Grasp.MCP.Server
```

`Grasp.MCP.Tools`:

```elixir
defmodule Grasp.MCP.Tools do
  @moduledoc "Shared plumbing for the MCP tools: the loaded index and JSON/error replies."

  alias Anubis.Server.Response

  @doc "The loaded index, or the tool error every tool replies with when none is loaded."
  @spec index() :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index do
    case Grasp.IndexStore.get() do
      nil -> {:error, Response.error(Response.tool(), "no index loaded")}
      index -> {:ok, index}
    end
  end

  @doc "A JSON tool reply."
  @spec reply(term(), term()) :: {:reply, Response.t(), term()}
  def reply(frame, data), do: {:reply, Response.json(Response.tool(), data), frame}

  @doc "A tool error reply."
  @spec error(term(), String.t()) :: {:reply, Response.t(), term()}
  def error(frame, message), do: {:reply, Response.error(Response.tool(), message), frame}
end
```

Each tool follows the Anubis component pattern (`use Anubis.Server.Component, type: :tool`, `schema do … end`, `@impl true def execute(params, frame)`), with a one-line `@moduledoc` that doubles as the tool description clients see (check whether Anubis reads `@moduledoc` or a `description:` option and use whichever it does). Keep the record slimming for `get_function` in that module (`Map.drop(record, ["base_source"])`). `find_paths` clamps `max_depth` to 1..8 and `limit` to 1..20 with `min/max` (the schema's `max:` constraint is nicer if the DSL supports it — prefer the schema).

Confirm the `list_entry_points` `query` match is over `label` and `target`, downcased.

- [ ] **Step 4: Run, format, commit** — `mix test` (all green, including the older 91); `mix compile --warnings-as-errors`. Commit: `MCP server at /mcp with the read tools`.

---

### Task 5: MCP session tools

**Files:**
- Create: `grasp/lib/grasp/mcp/tools/get_session.ex`, `set_cards.ex`, `open_card.ex`, `close_card.ex`, `focus_card.ex`, `highlight_card.ex`, `grasp/lib/grasp/mcp/cards.ex` (validation + linking, pure over the index)
- Modify: `grasp/lib/grasp/mcp/server.ex` (register the six components)
- Test: `grasp/test/grasp/mcp/cards_test.exs`, `grasp/test/grasp/mcp/session_tools_test.exs`, extend `grasp/test/grasp_web/mcp_test.exs`

**Interfaces:**
- Consumes: Task 1 (`Session.set_cards/2`, `set_highlight/3`, `Forest.to_map/1`), Task 4 helpers.
- Produces:
  - `Grasp.MCP.Cards.prepare(index, cards) :: {:ok, [Forest.spec()]} | {:error, String.t()}` — `cards` is the list of atom-keyed maps from the schema (`key`, `function_id`, `parent_key`, `highlight`). Resolves each `function_id` to its canonical id (`Index.fetch_function/2`), collects unknown ids into one message `"unknown functions: A.f/0, B.g/1"`; checks `parent_key` references (message `"unknown parent key: x"`); validates each highlight with `validate_highlight/3` below; sets `opened_by` to the parent's raw call target that resolves to the child (`Enum.find(parent_record["calls"] ++ parent_record["hidden_calls"], &(canonical(&1["target"]) == child_id))["target"]`), else the child id.
  - `Grasp.MCP.Cards.validate_highlight(index, function_id, highlight) :: {:ok, Forest.highlight()} | {:error, String.t()}` — nil → `{:ok, nil}`; `%{call: target}` must resolve to a call of the function's record (visible or hidden); the stored value is the record's raw target string (`%{"call" => raw}`) so the card's `.call[data-target]` matches; `%{lines: [a, b]}` must satisfy `span.start_line <= a <= b <= span.end_line`; anything else → error text.
  - Tool contracts (all take `session: string default "default"`, all reply with `Forest.to_map/1` of the resulting forest):
    - `get_session` → forest.
    - `set_cards` — `cards: embeds_many` of `key: string required`, `function_id: string required`, `parent_key: string`, `highlight: embeds_one` of `call: string`, `lines: {:list, :integer}`. Errors from `prepare/2` are tool errors; forest untouched.
    - `open_card` — `function_id required`, `parent_card_id: integer`, `highlight` (same embed) → opens a root or a child (`Session.open_child/4` with `opened_by` computed as above; unknown parent card → error `"unknown card: 7"`), then applies the highlight; reply adds `"card_id" => id` next to the forest keys.
    - `close_card` / `focus_card` — `card_id: integer required`; unknown → error.
    - `highlight_card` — `card_id required`, `highlight` required embed (an empty embed clears) → validated against the card's function.

If nesting `embeds_one` inside `embeds_many` fails to compile or validate in Anubis 2.0, fall back to two flat fields on the card entry (`highlight_call: string`, `highlight_lines: {:list, :integer}`) and the same on `open_card`/`highlight_card`; record which shape shipped in the report.

- [ ] **Step 1: Failing tests**

`cards_test.exs`:

```elixir
defmodule Grasp.MCP.CardsTest do
  use ExUnit.Case, async: true

  alias Grasp.MCP.Cards

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @hello_render "SampleAppWeb.HelloLive.render/1"

  setup_all do
    {:ok, index} = Grasp.Index.load("test/fixtures/index.json")
    %{index: index}
  end

  test "prepare resolves aliases and links children through the parent's call", %{index: index} do
    cards = [
      %{key: "root", function_id: @show, parent_key: nil, highlight: nil},
      %{key: "g", function_id: "SampleApp.Greeter.greet/1", parent_key: "root", highlight: %{call: @wrap, lines: nil}},
      %{key: "w", function_id: @wrap, parent_key: "g", highlight: %{call: nil, lines: [21, 22]}}
    ]

    assert {:ok, [root, g, w]} = Cards.prepare(index, cards)
    assert %{function_id: @show, parent_key: nil, opened_by: nil} = root
    # the controller calls greet/1; the card shows the canonical greet/2 but is linked by the raw target
    assert %{function_id: @greet, parent_key: "root", opened_by: "SampleApp.Greeter.greet/1", highlight: %{"call" => @wrap}} = g
    assert %{function_id: @wrap, opened_by: @wrap, highlight: %{"lines" => [21, 22]}} = w
  end

  test "a hidden call links too", %{index: index} do
    cards = [
      %{key: "r", function_id: @hello_render, parent_key: nil, highlight: nil},
      %{key: "g", function_id: @greet, parent_key: "r", highlight: nil}
    ]
    assert {:ok, [_, %{opened_by: "SampleApp.Greeter.greet/1"}]} = Cards.prepare(index, cards)
  end

  test "unknown functions and parents are one readable error", %{index: index} do
    cards = [%{key: "a", function_id: "Nope.f/0", parent_key: nil, highlight: nil},
             %{key: "b", function_id: "Nope.g/0", parent_key: "zzz", highlight: nil}]
    assert {:error, msg} = Cards.prepare(index, cards)
    assert msg =~ "unknown functions: Nope.f/0, Nope.g/0"
  end

  test "highlights are checked against the function", %{index: index} do
    assert {:ok, %{"call" => "SampleApp.Greeter.greet/1"}} = Cards.validate_highlight(index, @show, %{call: @greet, lines: nil})
    assert {:error, msg} = Cards.validate_highlight(index, @show, %{call: @wrap, lines: nil})
    assert msg =~ "does not call"
    assert {:error, _} = Cards.validate_highlight(index, @wrap, %{call: nil, lines: [1, 2]})
    assert {:ok, nil} = Cards.validate_highlight(index, @wrap, nil)
  end
end
```

Check `@wrap`'s span in the fixture before pinning `[21, 22]` and `[1, 2]` (the second must fall outside the span).

`session_tools_test.exs`: drive `execute/2` directly on a fresh session name: `set_cards` with two cards → forest JSON has two cards with the right parent; `open_card` under card 1 → `"card_id"`, `opened_by` set; `highlight_card` on it → highlight in JSON; `focus_card` → `"focus"`; `close_card` → card gone; `set_cards` with an unknown id → `isError` and `Grasp.Session.get(name)` unchanged; unknown `card_id` → `isError`.

`mcp_test.exs` addition: through HTTP, `set_cards` for a fresh session, then `live(conn, "/s/#{name}")` renders `#card-1[data-function-id='SampleAppWeb.GreetController.show/2']` and `#card-2 .call[data-highlight="true"]`.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** per the interfaces. Keep validation in `Grasp.MCP.Cards` (pure, index in, spec out) and the tools as adapters: parse params → `Cards` → `Session` → `Tools.reply(frame, Forest.to_map(forest))`. `Session.ensure(name)` before any session call.

- [ ] **Step 4: Run, format, commit** — `MCP session tools: set_cards, open, close, focus, highlight`.

---

### Task 6: `Grasp.Agent` — the CLI runner

**Files:**
- Create: `grasp/lib/grasp/agent.ex` (facade), `grasp/lib/grasp/agent/runner.ex` (GenServer), `grasp/lib/grasp/agent/stream.ex` (pure event → transcript), `grasp/lib/grasp/agent/command.ex` (pure argv builder), `grasp/test/support/fake_claude.sh` (executable), 
- Modify: `grasp/lib/grasp/application.ex` (Registry `Grasp.AgentRegistry`, `DynamicSupervisor Grasp.AgentSupervisor`), `grasp/config/config.exs` (`config :grasp, agent_command: "claude", agent_model: nil`), `grasp/config/test.exs` (`agent_command: Path.expand("test/support/fake_claude.sh", __DIR__ <> "/..")` — compute a path that is absolute at test time), `grasp/config/runtime.exs` (`GRASP_AGENT_COMMAND`, `GRASP_AGENT_MODEL`)
- Test: `grasp/test/grasp/agent/stream_test.exs`, `grasp/test/grasp/agent/command_test.exs`, `grasp/test/grasp/agent/runner_test.exs`

**Interfaces:**
- Produces:
  - `Grasp.Agent.Stream.apply(state(), String.t()) :: state()` — folds one output line into a transcript state `%{entries: [entry()], claude_session_id: String.t() | nil, log: [String.t()], done?: boolean()}`. Entries (newest last): `%{type: :user, text}`, `%{type: :assistant, text}` (consecutive assistant text blocks merge into one entry), `%{type: :tool, name, summary, status: :running | :done | :error}`, `%{type: :error, text}`, `%{type: :done, cost_usd: float | nil, turns: integer | nil}`. A non-JSON line goes to `log`. Rules: `system/init` → session id; if its `mcp_servers` list has no `%{"name" => "grasp", "status" => "connected"}` append `%{type: :error, text: "grasp MCP server not connected (status: <status or missing>)"}`. `assistant` → for each content block: `text` → assistant entry; `tool_use` → tool entry with `name` stripped of a leading `mcp__grasp__` and `summary` = the first present of `input["query"]`, `input["id"]`, `input["to"]`, `input["function_id"]`, `input["file_path"]`, `input["pattern"]`, `"#{length(input["cards"])} cards"` when `cards` is a list, else `""`. `user` → for each `tool_result` block, the oldest `:running` tool entry becomes `:done`, or `:error` when `is_error` is true. `result` → `done?: true`, append `:done` with `total_cost_usd` and `num_turns`; when `is_error` is true also append `%{type: :error, text: result["result"] || subtype}`. `rate_limit_event` and unknown types are ignored. `Stream.new() :: state()`.
  - `Grasp.Agent.Command.build(prompt, opts) :: {String.t(), [String.t()]}` with `opts :: [command: String.t(), session: String.t(), mcp_url: String.t(), resume: String.t() | nil, model: String.t() | nil]` → `{command, argv}`. argv, in this order: `["-p", prompt, "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config", mcp_json, "--tools", "Read,Grep,Glob", "--allowedTools", "mcp__grasp,Read,Grep,Glob", "--max-turns", "60", "--append-system-prompt", system_prompt]` then `["--resume", id]` when `resume`, then `["--model", model]` when `model`. `mcp_json` is `Jason.encode!(%{"mcpServers" => %{"grasp" => %{"type" => "http", "url" => mcp_url}}})`. `Command.system_prompt(session) :: String.t()` returns the text below. `Command.mcp_url() :: String.t()` builds `"http://127.0.0.1:#{port}/mcp"` from `Application.get_env(:grasp, GraspWeb.Endpoint)[:http][:port]` (default 4040). `Command.cwd() :: String.t()` returns the index's `project["root"]` when `File.dir?/1`, else `File.cwd!()`.
  - `Grasp.Agent` facade: `ensure(name) :: :ok`, `subscribe(name) :: :ok`, `get(name) :: view()`, `send_prompt(name, prompt) :: :ok | {:error, :running | :no_command}`, `stop(name) :: :ok`, `reset(name) :: :ok` (clears entries, log and session id; stops a run first). `view :: %{entries: [entry()], running?: boolean(), claude_session_id: String.t() | nil, log: [String.t()], last_result: String.t() | nil}`; the broadcast is `{:agent, name, view}` on `"agent:" <> name` via `Grasp.PubSub`, sent after every change.
  - Runner internals: `Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, {:line, 1_048_576}, {:args, argv}, {:cd, cwd}])` where `exe = System.find_executable(command) || command` (an absolute path passes through); `{:error, :no_command}` when neither resolves to an existing file. Handle `{port, {:data, {:eol, line}}}` (apply), `{port, {:data, {:noeol, chunk}}}` (buffer until eol), `{port, {:exit_status, code}}` → `running?: false`; when `code != 0` and the state is not `done?`, append `%{type: :error, text: "claude exited with status #{code}"}` (the log is shown by the UI). On `send_prompt` append the `:user` entry first, broadcast, then spawn. `stop/1`: `Port.info(port, :os_pid)` → `System.cmd("kill", ["-TERM", Integer.to_string(pid)])`, then `Port.close/1` guarded by a `rescue`/`catch` for an already-closed port; mark `running?: false`, append `%{type: :error, text: "stopped"}`.

System prompt text (`Command.system_prompt/1`), verbatim:

```
You are the review assistant inside Grasp, a call-chain code review tool. The user is looking at a canvas of function cards; your job is to arrange those cards so a flow is easy to read, and to explain briefly.

The Grasp viewer session you control is "<session>". Pass session: "<session>" to every grasp card tool.

Work like this:
1. Discover with the grasp read tools: search_functions, get_function, get_callers, get_callees, list_entry_points, find_paths (with only `to` it walks callers back to entry points such as controller actions, LiveView callbacks and Oban workers).
2. Answer with set_cards: one call that lays out the whole flow as a tree, roots at the entry points, each callee a child of the function that calls it, in call order. Add a highlight on a card when one call or line range is the point of interest.
3. Reply in a few sentences: what the flow does and where to look first. The cards are the answer; do not paste source code.

Do not edit files or run commands. If a function is not in the index, say so.
```

Fake CLI `test/support/fake_claude.sh` (mode `chmod +x`, committed executable):

```sh
#!/bin/sh
# Stands in for the Claude Code CLI in tests: prints a canned stream-json run whose result
# echoes the argv, so tests can assert on the flags the runner passed.
args="$*"
case "$args" in
  *FAIL*)
    echo '{"type":"system","subtype":"init","session_id":"fake-fail","mcp_servers":[{"name":"grasp","status":"failed"}]}'
    echo 'something went wrong on stderr' 1>&2
    exit 3
    ;;
esac
echo '{"type":"system","subtype":"init","session_id":"fake-1","mcp_servers":[{"name":"grasp","status":"connected"}]}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the flow."}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__grasp__search_functions","input":{"query":"greet","limit":5}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"[]"}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":" Done."}]}}'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.01,"session_id":"fake-1","result":%s}\n' "$(printf '%s' "$args" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
```

(The `result` field carries the argv as a JSON string; if quoting the JSON inside `--mcp-config` through `sed` proves brittle, write the argv to `$FAKE_CLAUDE_ARGV_FILE` when that variable is set and let the test read the file instead — the runner passes the environment through by default.)

- [ ] **Step 1: Failing tests**

`stream_test.exs`: fold the six canned lines above (as literal strings) through `Stream.apply/2` and assert: `claude_session_id == "fake-1"`, entries are `[assistant "Looking at the flow. Done.", tool %{name: "search_functions", summary: "greet", status: :done}, done %{cost_usd: 0.01, turns: 2}]` in that order (the assistant merge produces one entry even with a tool between? **No** — a tool between two text blocks splits them: expect `[assistant "Looking at the flow.", tool …, assistant " Done.", done]`; merging applies only to consecutive assistant text); a non-JSON line lands in `log`; an init with `status: "failed"` yields an `:error` entry mentioning `failed`; a `result` with `is_error: true` yields an `:error` entry; a `tool_use` with `input: %{"cards" => [1, 2, 3]}` summarises as `"3 cards"`.

`command_test.exs`: `build("hi", command: "claude", session: "s1", mcp_url: "http://127.0.0.1:4040/mcp", resume: nil, model: nil)` → `{"claude", argv}` where `argv` starts with `["-p", "hi", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config", json | _]` and `Jason.decode!(json)["mcpServers"]["grasp"]["url"] == "http://127.0.0.1:4040/mcp"`; `"--resume"` absent; with `resume: "abc"` the argv ends with `["--resume", "abc"]`; with `model: "opus"` it ends with `["--model", "opus"]` (after resume); the system prompt contains `session: "s1"`; `mcp_url()` in test is `"http://127.0.0.1:4041/mcp"`; `cwd()` is `File.cwd!()` because the fixture root `/tmp/sample_app` does not exist (assert `File.dir?("/tmp/sample_app") == false` first so the test says why).

`runner_test.exs`:

```elixir
  setup do
    name = "t-#{System.unique_integer([:positive])}"
    :ok = Grasp.Agent.ensure(name)
    :ok = Grasp.Agent.subscribe(name)
    %{name: name}
  end

  test "a prompt runs the command and streams the transcript", %{name: name} do
    assert :ok = Grasp.Agent.send_prompt(name, "show me greet")
    assert_receive {:agent, ^name, %{running?: true, entries: [%{type: :user, text: "show me greet"}]}}
    assert_receive {:agent, ^name, %{running?: false, entries: entries, claude_session_id: "fake-1"}}, 2_000
    assert Enum.map(entries, & &1.type) == [:user, :assistant, :tool, :assistant, :done]
    assert %{type: :done, cost_usd: 0.01} = List.last(entries)
    %{last_result: argv} = Grasp.Agent.get(name)
    assert argv =~ "--strict-mcp-config"
    assert argv =~ "/mcp"
    assert argv =~ ~s(session: \\"#{name}\\")
  end
```

The `:done` entry does not carry the result text, so `Stream` keeps `result_text` in its state (the `result` event's `"result"` field) and the runner exposes it in the view as `last_result: String.t() | nil`. Further tests: a second prompt after the first finishes passes `--resume fake-1` (assert on `last_result`); `send_prompt` while running returns `{:error, :running}` (use a prompt containing `SLOW` and make the fake script `sleep 1` when it sees `SLOW`, before printing the result); `stop/1` during `SLOW` ends with `running?: false` and an `:error "stopped"` entry within 1 s; a `FAIL` prompt yields an `:error` entry mentioning `status 3` and `log` containing `"something went wrong on stderr"`; `reset/1` empties entries and clears `claude_session_id` so the next run has no `--resume`; with `Application.put_env(:grasp, :agent_command, "/definitely/not/here")` (restore in `on_exit`; this test cannot be async with the others — put it in its own module with `async: false`) `send_prompt` returns `{:error, :no_command}`.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** per the interfaces. `Grasp.Agent.ensure/1` starts the runner under `Grasp.AgentSupervisor` via `Grasp.AgentRegistry` the way `Grasp.Session.ensure/1` does. Keep `Stream` and `Command` pure and fully covered; the runner is thin.

- [ ] **Step 4: Run, format, commit** — `Agent runner drives the Claude Code CLI over MCP`.

---

### Task 7: The chat panel

**Files:**
- Create: `grasp/lib/grasp_web/components/chat_panel.ex`, `grasp/assets/js/hooks/chat.js`
- Modify: `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/js/app.js`, `grasp/assets/js/hooks/keys.js`, `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/chat_test.exs`

**Interfaces:**
- Consumes: `Grasp.Agent` facade and view from Task 6.
- Produces:
  - `ReviewLive` assigns `chat_open?: false`, `agent: Grasp.Agent.get(name)`; in `mount` when connected: `Grasp.Agent.ensure(name)` and `Grasp.Agent.subscribe(name)`; `handle_info({:agent, name, view}, socket)` assigns `agent`. Events: `"chat_toggle"`, `"chat_send"` with `%{"prompt" => p}` (ignores blank; on `{:error, :running}` flashes nothing, the Send button is disabled anyway; on `{:error, :no_command}` assigns `chat_error: "claude command not found; set GRASP_AGENT_COMMAND"` rendered in the panel), `"chat_stop"`, `"chat_reset"`.
  - `GraspWeb.ChatPanel.chat_panel/1` with attrs `open? :boolean`, `agent :map`, `error :string default nil`. Markup: `<aside id="chat" class="chat" phx-hook="Chat" hidden={!@open?}>` containing `<div class="chat__log" id="chat-log">` of entries (`.msg[data-type="user|assistant|tool|error|done"]`; tool rows show `name` and `summary` and `data-status`; the `:done` row shows `$0.01 · 2 turns` when cost is present; assistant text renders with `white-space: pre-wrap`), a `<details class="chat__debug">` listing `log` lines when the last entry is an error and the log is non-empty, and a `<form phx-submit="chat_send">` with `<input name="prompt" id="chat-prompt" autocomplete="off" placeholder="Ask about a flow…">` plus buttons `Send` (`disabled={@agent.running?}`), `Stop` (`phx-click="chat_stop"`, shown while running), `New` (`phx-click="chat_reset"`, `disabled` while running).
  - `Chat` hook: `updated()` scrolls `#chat-log` to the bottom; after a submit the input is cleared server-side by re-rendering `value=""`? No — the input is uncontrolled; instead the hook listens to the form's `submit` event and clears the input after `pushEvent` (use `phx-hook` on the aside and `this.el.querySelector("form").addEventListener("submit", …)` clearing `input.value` on the next tick). On open (`hidden` removed) focus the input.
  - Keys hook: in the meta/ctrl branch, `e.key === "i"` → `preventDefault()` and `pushEvent("chat_toggle", {})`. Toolbar: a button `id="toggle-chat"` `phx-click="chat_toggle"` titled `Ask the agent (⌘I)` with the text `ask`.
  - CSS: `.chat { position: absolute; inset-block-end: var(--space-m); inset-inline-end: var(--space-m); z-index: 4; width: 28rem; max-height: 60vh; display: flex; flex-direction: column; background: var(--bg-raised); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); font-size: 13px; }`, `.chat__log { overflow-y: auto; padding: var(--space-s) var(--space-m); display: flex; flex-direction: column; gap: var(--space-xs); }`, `.msg[data-type="user"] { align-self: flex-end; background: var(--accent-soft); border-radius: var(--radius); padding: var(--space-xs) var(--space-s); }`, `.msg[data-type="assistant"] { white-space: pre-wrap; }`, `.msg[data-type="tool"] { font-family: var(--mono); font-size: 12px; color: var(--fg-muted); }`, `.msg[data-type="tool"][data-status="running"]::before { content: "… "; }`, `.msg[data-type="tool"][data-status="done"]::before { content: "✓ "; }`, `.msg[data-type="tool"][data-status="error"]::before { content: "✗ "; color: var(--danger); }`, `.msg[data-type="error"] { color: var(--danger); }`, `.msg[data-type="done"] { color: var(--fg-subtle); font-size: 12px; }`, `.chat form { display: flex; gap: var(--space-xs); padding: var(--space-s); border-top: 1px solid var(--border); }`, `.chat input { flex: 1; font: inherit; padding: var(--space-xs) var(--space-s); border: 1px solid var(--border); border-radius: 4px; background: var(--bg-sunken); color: var(--fg); }`. The canvas's `user-select: none` must not apply inside the panel: `.chat { user-select: text; cursor: auto; }`, and the Canvas hook's `pointerDown` must ignore events inside `.chat` (add `.chat` to the `closest(...)` exclusion list so a click in the panel never starts a pan).

- [ ] **Step 1: Failing tests** — `chat_test.exs` (`use GraspWeb.ConnCase, async: true`, same `setup` as `review_live_test.exs`):

```elixir
  test "the panel toggles from the toolbar and starts hidden", %{view: view} do
    assert has_element?(view, "#chat[hidden]")
    view |> element("#toggle-chat") |> render_click()
    refute has_element?(view, "#chat[hidden]")
    assert has_element?(view, "#chat input#chat-prompt")
  end

  test "sending a prompt streams the transcript into the panel", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat form", %{"prompt" => "show me greet"}) |> render_submit()
    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "show me greet")

    :ok = Grasp.Agent.subscribe(name)
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    html = render(view)
    assert html =~ "Looking at the flow."
    assert has_element?(view, ~s(#chat .msg[data-type="tool"][data-status="done"]), "search_functions")
    assert has_element?(view, ~s(#chat .msg[data-type="done"]), "2 turns")
    refute has_element?(view, "#chat button[disabled]", "Send")
  end

  test "a blank prompt is ignored", %{view: view} do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat form", %{"prompt" => "   "}) |> render_submit()
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))
  end

  test "a failed run shows the error and the log", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat form", %{"prompt" => "FAIL please"}) |> render_submit()
    :ok = Grasp.Agent.subscribe(name)
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert has_element?(view, ~s(#chat .msg[data-type="error"]), "status 3")
    assert has_element?(view, "#chat .chat__debug", "something went wrong on stderr")
  end
```

If the `subscribe` after `render_submit` can miss the final broadcast (the run is fast), subscribe **before** submitting in each test.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** per the interfaces. `mix assets.build` must succeed; open the page in a browser only if a server is already running — do not start one.

- [ ] **Step 4: Run, format, commit** — `Chat panel: ask the agent from the viewer`.

---

### Task 8: Serve flags, README and spec gaps

**Files:**
- Modify: `grasp/lib/mix/tasks/grasp.serve.ex` (`--agent-command PATH`, `--agent-model NAME` → `GRASP_AGENT_COMMAND`, `GRASP_AGENT_MODEL`; document in the moduledoc)
- Modify: `README.md` (sections "MCP" and "Ask the agent": how to register in Claude Code, what the tools are, that the panel runs the Claude Code CLI with read-only tools against the project root, the env vars, and that Anubis MCP is LGPL-3.0 and used as an unmodified dependency)
- Modify: `docs/specs/2026-09-15-grasp-design.md` — add `### Known gaps (milestone 4)`: one run at a time per session; the panel needs the `claude` CLI on PATH (or `GRASP_AGENT_COMMAND`); no annotations or tours yet; `find_paths` visit budget 20 000; the agent's built-in tools are `Read`, `Grep`, `Glob` only; transcripts are in memory and vanish with the viewer.
- Test: `grasp/test/mix/tasks/grasp_serve_test.exs` if one exists — extend for the two flags; otherwise a unit test of the option parsing is not required.

- [ ] **Step 1: Implement the flags** mirroring `--editor` (parse, `System.put_env`, `runtime.exs` reads them into `:grasp, :agent_command` / `:agent_model`).
- [ ] **Step 2: Write the docs.** No project names other than `SampleApp`.
- [ ] **Step 3: Verify** `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` in `grasp/`.
- [ ] **Step 4: Commit** — `Serve flags and docs for the agent and MCP`.
