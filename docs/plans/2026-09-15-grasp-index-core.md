# Grasp Index Core (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `grasp_index`, the Mix dependency that writes a JSON index of every function in an Elixir project with its compiler-resolved calls and their source ranges.

**Architecture:** `mix grasp.index` runs inside the target project. It registers a compiler tracer, forces a full recompile so the Elixir compiler reports every resolved call with its position, extracts definitions and call-node ranges from each source file with Sourceror, joins the two by caller MFA plus line and column, and writes one JSON document. `Grasp.Index` is the reader the viewer (milestone 2) will use: it loads the document, resolves default-argument arities, inverts callers and searches ids.

**Tech Stack:** Elixir 1.20.4 / OTP 29 (`.mise.toml`), Sourceror ~> 1.10, Jason ~> 1.4, ExUnit. No Phoenix in this package.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 (`grasp_index`), pipeline steps 1, 2, 3 and 6, and the `Grasp.Index` reader. Steps 4 (entry points) and 5 (base ref) are milestones 3 and 4 and are NOT in this plan; the JSON still carries their fields with defaults (`entry_points: []`, `change: "unchanged"`, `base_source: null`, `removed: false`).

## Global Constraints

- `grasp_index` requires Elixir `~> 1.19` (`test_ignore_filters`); deps are exactly `sourceror`, `jason` and `ex_doc` (dev only). Never add Phoenix or the viewer's deps here.
- Function ids are `"<module>.<name>/<arity>"` where module is `inspect(module)` (`MyApp.Wallets`, `:erlang`). A definition's canonical id uses its maximum arity; every arity a default argument introduces is listed in `arities`.
- Ranges are `{line, column}` pairs, 1-based, end column exclusive, in file coordinates (source text keeps its indentation). In JSON they serialise as `[line, column]`.
- Every module has a `@moduledoc`; every public function has `@doc` and `@spec`. Comments only where the why is non-obvious. Never nest two modules in one file. Predicates end in `?`.
- Run `mix format` in `grasp_index/` before every commit. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The repo is public: no references to the author's employer's projects in code, fixtures, docs or commits. Use `MyApp`/`SampleApp` names.
- Tests that touch `Code.put_compiler_option/2` are `async: false` and restore the previous options in `after`.

---

## File structure

```
grasp_index/
  mix.exs                          # project, deps, hex package metadata
  .formatter.exs
  README.md                        # install + usage, JSON shape pointer
  lib/grasp/index.ex               # Grasp.Index — reader: load, fetch, callers, callees, search
  lib/grasp/index/tracer.ex        # Grasp.Index.Tracer — compiler tracer -> ETS
  lib/grasp/index/extract.ex       # Grasp.Index.Extract — Sourceror: definitions + call sites per file
  lib/grasp/index/join.ex          # Grasp.Index.Join — events + definitions -> function records, ids
  lib/grasp/index/builder.ex       # Grasp.Index.Builder — orchestrates inside Mix, git info, writes JSON
  lib/mix/tasks/grasp.index.ex     # Mix.Tasks.Grasp.Index
  test/test_helper.exs
  test/support/compile.ex          # Grasp.TestSupport.Compile — trace-compile a source string
  test/grasp/index/tracer_test.exs
  test/grasp/index/extract_test.exs
  test/grasp/index/join_test.exs
  test/grasp/index_test.exs
  test/grasp/index/builder_test.exs        # integration: runs mix grasp.index in the fixture
  test/fixtures/sample_app/mix.exs
  test/fixtures/sample_app/lib/sample_app/greeter.ex
  test/fixtures/sample_app/lib/sample_app/formatter.ex
```

Data flows `Tracer.events()` + `Extract.extract/2` → `Join.join/2` → `Builder` JSON → `Grasp.Index.load/1`.

---

### Task 1: Mix project scaffold

**Files:**
- Create: `grasp_index/mix.exs`, `grasp_index/.formatter.exs`, `grasp_index/README.md`, `grasp_index/test/test_helper.exs`
- Modify: `.gitignore` (repo root), `docs/specs/2026-09-15-grasp-design.md` (scrub employer names)

**Interfaces:**
- Produces: the `:grasp_index` OTP app; `mix test` runs in `grasp_index/`.

- [ ] **Step 1: Create the Mix project files**

`grasp_index/mix.exs`:

```elixir
defmodule GraspIndex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gfrancischelli/grasp"

  def project do
    [
      app: :grasp_index,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      description:
        "Indexer for Grasp: a compiler-traced call graph of an Elixir project, as JSON",
      package: package(),
      name: "Grasp Index",
      docs: [main: "readme", extras: ["README.md"], source_url: @source_url]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.10"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
```

`grasp_index/.formatter.exs`:

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

`grasp_index/test/test_helper.exs`:

```elixir
ExUnit.start()
```

`grasp_index/README.md`:

```markdown
# grasp_index

The indexer half of [Grasp](../README.md). Add it to the project you want to review:

```elixir
{:grasp_index, "~> 0.1", only: :dev, runtime: false}
```

Then:

```
mix grasp.index [--out .grasp/index.json]
```

The task forces a full recompile with a compiler tracer attached, so every call the
compiler resolves is recorded with the position of the call in your source, then joins
those calls with the function definitions Sourceror finds and writes one JSON document.
The Grasp viewer and its MCP server read that document; `Grasp.Index` in this package is
the reader they use.

The document shape is described in `docs/specs/2026-09-15-grasp-design.md` at the repo
root under "Index JSON".
```

- [ ] **Step 2: Fix the gitignore so nested `_build`/`deps` (fixture app included) are ignored**

Replace the four `*/…` lines in the root `.gitignore` with:

```
**/_build/
**/deps/
**/doc/
**/cover/
```

- [ ] **Step 3: Scrub employer-specific names from the spec**

In `docs/specs/2026-09-15-grasp-design.md`: rewrite every example that names a real private application so it uses the generic `MyApp` / `MyAppWeb` / `my_app` placeholders instead — the module names in the Index JSON sample, the `project.app` value, the `lib/<app>/` source paths, and the `--index` path in the `mix grasp.serve` example (which becomes `../my_app/.grasp/index.json`). Then grep `docs/` and `README.md` case-insensitively for the old application name and expect no output.

- [ ] **Step 4: Fetch deps, compile, run the empty suite**

Run from `grasp_index/`: `mix deps.get && mix compile --warnings-as-errors && mix test`
Expected: deps fetched, compiles with no warnings, `0 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/grasp && git add -A && git commit -m "Scaffold grasp_index Mix project

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Compiler tracer

**Files:**
- Create: `grasp_index/lib/grasp/index/tracer.ex`, `grasp_index/test/support/compile.ex`
- Test: `grasp_index/test/grasp/index/tracer_test.exs`

**Interfaces:**
- Produces: `Grasp.Index.Tracer.start/0`, `stop/0`, `events/0 :: [event()]`, `trace/2` (compiler callback). `event()` is
  `%{file: String.t(), module: module(), function: {atom(), non_neg_integer()}, line: pos_integer(), column: pos_integer() | nil, target: {module(), atom(), non_neg_integer()}, kind: :remote | :local | :imported | :remote_macro | :local_macro | :imported_macro}`.
- Produces (test only): `Grasp.TestSupport.Compile.trace(source, file) :: [event()]`.

- [ ] **Step 1: Write the failing test**

`grasp_index/test/grasp/index/tracer_test.exs`:

```elixir
defmodule Grasp.Index.TracerTest do
  use ExUnit.Case, async: false

  alias Grasp.TestSupport.Compile

  @source ~S"""
  defmodule Grasp.TracerTest.Sample do
    alias Enum, as: E
    import String, only: [upcase: 1]

    def run(list) do
      E.map(list, &helper/1)
      upcase("a")
      helper(1)
    end

    defp helper(x), do: x
  end
  """

  test "records remote, local and imported calls with the function name's position" do
    events = Compile.trace(@source, "lib/sample.ex")

    assert %{kind: :remote, line: 6, column: 7, target: {Enum, :map, 2}} = find(events, {Enum, :map, 2})
    assert %{kind: :local, line: 6, column: 18} = find(events, {Grasp.TracerTest.Sample, :helper, 1})
    assert %{kind: :imported, line: 7, column: 5, target: {String, :upcase, 1}} = find(events, {String, :upcase, 1})

    assert Enum.all?(events, &(&1.module == Grasp.TracerTest.Sample))
    assert Enum.all?(events, &(&1.file == "lib/sample.ex"))
  end

  test "attributes every event to the enclosing function" do
    events = Compile.trace(@source, "lib/sample.ex")

    assert Enum.all?(events, &match?({name, arity} when is_atom(name) and is_integer(arity), &1.function))
    assert Enum.map(find_all(events, {Grasp.TracerTest.Sample, :helper, 1}), & &1.function) == [{:run, 1}, {:run, 1}]
  end

  test "ignores module-body events such as def registration" do
    events = Compile.trace(@source, "lib/sample.ex")

    refute Enum.any?(events, &(&1.target == {Kernel, :def, 2}))
    refute Enum.any?(events, &(&1.target == {Kernel, :defp, 2}))
  end

  test "events/0 is empty after start/0 and stop/0 removes the table" do
    Grasp.Index.Tracer.start()
    assert Grasp.Index.Tracer.events() == []
    Grasp.Index.Tracer.stop()
    assert :ets.whereis(:grasp_index_tracer_events) == :undefined
  end

  defp find(events, target), do: Enum.find(events, &(&1.target == target))
  defp find_all(events, target), do: Enum.filter(events, &(&1.target == target))
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd grasp_index && mix test test/grasp/index/tracer_test.exs`
Expected: compile error, `Grasp.TestSupport.Compile` / `Grasp.Index.Tracer` undefined.

- [ ] **Step 3: Write the tracer and the test helper**

`grasp_index/lib/grasp/index/tracer.ex`:

```elixir
defmodule Grasp.Index.Tracer do
  @moduledoc """
  Compiler tracer that records every call the Elixir compiler resolves while a project
  compiles.

  Registered through `Code.put_compiler_option(:tracers, ...)` before compilation. The
  compiler calls `trace/2` from many processes in parallel, so events go into a public
  named ETS table created by `start/0` and are read back with `events/0`. Only calls
  made inside a function body are recorded: `env.function` is `nil` while a module body
  is being expanded (`use`, attributes, `def` registration), and those events describe
  compilation rather than the program.
  """

  @table :grasp_index_tracer_events

  @type kind :: :remote | :local | :imported | :remote_macro | :local_macro | :imported_macro

  @type event :: %{
          file: String.t(),
          module: module(),
          function: {atom(), non_neg_integer()},
          line: pos_integer(),
          column: pos_integer() | nil,
          target: {module(), atom(), non_neg_integer()},
          kind: kind()
        }

  @doc "Creates the event table, replacing any left over from a previous run."
  @spec start() :: :ok
  def start do
    stop()
    :ets.new(@table, [:duplicate_bag, :public, :named_table])
    :ok
  end

  @doc "Deletes the event table if it exists."
  @spec stop() :: :ok
  def stop do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  @doc "Returns every event recorded since `start/0`."
  @spec events() :: [event()]
  def events do
    @table |> :ets.tab2list() |> Enum.map(fn {:event, event} -> event end)
  end

  @doc false
  def trace({kind, meta, module, name, arity}, %Macro.Env{function: {_, _}} = env)
      when kind in [:remote_function, :imported_function, :remote_macro, :imported_macro] do
    record(env, meta, {module, name, arity}, kind_of(kind))
  end

  def trace({kind, meta, name, arity}, %Macro.Env{function: {_, _}} = env)
      when kind in [:local_function, :local_macro] do
    record(env, meta, {env.module, name, arity}, kind_of(kind))
  end

  def trace(_event, _env), do: :ok

  defp record(%Macro.Env{} = env, meta, target, kind) do
    if :ets.whereis(@table) != :undefined do
      event = %{
        file: env.file,
        module: env.module,
        function: env.function,
        line: Keyword.get(meta, :line, env.line),
        column: Keyword.get(meta, :column),
        target: target,
        kind: kind
      }

      :ets.insert(@table, {:event, event})
    end

    :ok
  end

  defp kind_of(:remote_function), do: :remote
  defp kind_of(:local_function), do: :local
  defp kind_of(:imported_function), do: :imported
  defp kind_of(:remote_macro), do: :remote_macro
  defp kind_of(:local_macro), do: :local_macro
  defp kind_of(:imported_macro), do: :imported_macro
end
```

`grasp_index/test/support/compile.ex`:

```elixir
defmodule Grasp.TestSupport.Compile do
  @moduledoc """
  Compiles a source string with `Grasp.Index.Tracer` attached and returns the events,
  restoring the global compiler options afterwards and purging the compiled modules so
  tests can reuse module names.
  """

  @doc "Trace-compiles `source` as if it lived at `file`; returns the tracer events."
  @spec trace(String.t(), String.t()) :: [Grasp.Index.Tracer.event()]
  def trace(source, file) do
    previous_tracers = Code.get_compiler_option(:tracers)
    previous_parser = Code.get_compiler_option(:parser_options)
    Grasp.Index.Tracer.start()
    Code.put_compiler_option(:tracers, [Grasp.Index.Tracer | previous_tracers])
    Code.put_compiler_option(:parser_options, Keyword.put(previous_parser, :columns, true))

    try do
      modules = Code.compile_string(source, file)
      events = Grasp.Index.Tracer.events()

      for {module, _bytecode} <- modules do
        :code.purge(module)
        :code.delete(module)
      end

      events
    after
      Code.put_compiler_option(:tracers, previous_tracers)
      Code.put_compiler_option(:parser_options, previous_parser)
      Grasp.Index.Tracer.stop()
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd grasp_index && mix test test/grasp/index/tracer_test.exs`
Expected: 4 tests, 0 failures. If the imported `upcase` column differs from 5, print `events` and adjust the assertion to what the compiler reports (the column must equal the position of `upcase` in the source, which is column 5 on line 7).

- [ ] **Step 5: Format and commit**

```bash
cd ~/repos/grasp/grasp_index && mix format && cd .. && git add -A && git commit -m "Add compiler tracer that records resolved calls with positions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Sourceror extraction

**Files:**
- Create: `grasp_index/lib/grasp/index/extract.ex`
- Test: `grasp_index/test/grasp/index/extract_test.exs`

**Interfaces:**
- Produces: `Grasp.Index.Extract.extract(source :: String.t(), file :: String.t()) :: {:ok, %{definitions: [definition()], modules: [module_info()]}} | {:error, term()}` with
  - `definition() :: %{module: String.t(), name: atom(), arity: non_neg_integer(), arities: [non_neg_integer()], kind: :def | :defp | :defmacro | :defmacrop | :defguard | :defguardp | :defdelegate, file: String.t(), start_line: pos_integer(), end_line: pos_integer(), source: String.t(), call_sites: [call_site()]}`
  - `call_site() :: %{line: pos_integer(), column: pos_integer(), range: range()}`
  - `range() :: %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}}`
  - `module_info() :: %{name: String.t(), file: String.t(), line: pos_integer()}`

- [ ] **Step 1: Write the failing tests**

`grasp_index/test/grasp/index/extract_test.exs`:

```elixir
defmodule Grasp.Index.ExtractTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Extract

  @source ~S"""
  defmodule Sample do
    # Says hi.
    @doc "Greets."
    @spec greet(String.t(), boolean()) :: String.t()
    def greet(name, loud? \\ false) do
      text = Formatter.wrap(name)
      if loud?, do: shout(text), else: text
    end

    def count(list) when is_list(list), do: length(list)
    def count(_), do: 0

    defmodule Nested do
      def hello, do: Sample.greet("n")
    end

    defmodule __MODULE__.Deep do
      defp hidden, do: :ok
    end
  end
  """

  test "groups clauses and attaches doc, spec and leading comments to the span" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    greet = find(defs, "Sample", :greet)
    assert %{arity: 2, arities: [1, 2], kind: :def, file: "lib/sample.ex"} = greet
    assert greet.start_line == 2
    assert greet.end_line == 8
    assert greet.source == @source |> String.split("\n") |> Enum.slice(1, 7) |> Enum.join("\n")

    count = find(defs, "Sample", :count)
    assert %{arity: 1, arities: [1], start_line: 10, end_line: 11} = count
    assert String.starts_with?(count.source, "  def count(list) when")
    assert String.ends_with?(count.source, "def count(_), do: 0")
  end

  test "resolves nested and __MODULE__-prefixed module names" do
    {:ok, %{definitions: defs, modules: modules}} = Extract.extract(@source, "lib/sample.ex")

    assert %{kind: :def, start_line: 14, end_line: 14} = find(defs, "Sample.Nested", :hello)
    assert %{kind: :defp} = find(defs, "Sample.Deep", :hidden)

    assert modules == [
             %{name: "Sample", file: "lib/sample.ex", line: 1},
             %{name: "Sample.Nested", file: "lib/sample.ex", line: 13},
             %{name: "Sample.Deep", file: "lib/sample.ex", line: 17}
           ]
  end

  test "collects call sites keyed by the function name position, ranging over the callee only" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    greet = find(defs, "Sample", :greet)

    assert %{range: %{start: {6, 12}, end: {6, 26}}} = site(greet, 6, 22)
    assert %{range: %{start: {7, 19}, end: {7, 24}}} = site(greet, 7, 19)

    count = find(defs, "Sample", :count)
    assert %{range: %{start: {10, 24}, end: {10, 31}}} = site(count, 10, 24)
  end

  @kinds ~S"""
  defmodule Ops do
    defdelegate size(x), to: Enum, as: :count
    defguard is_pos(x) when x > 0
    def zero, do: 0
    def all(list), do: Enum.map(list, &double/1)
    defp double(x), do: x * 2
    defmacro twice(x), do: quote(do: unquote(x) * 2)
  end
  """

  test "recognises every definition kind and parenless heads" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")

    assert %{kind: :defdelegate, arity: 1} = find(defs, "Ops", :size)
    assert %{kind: :defguard, arity: 1} = find(defs, "Ops", :is_pos)
    assert %{kind: :def, arity: 0, arities: [0]} = find(defs, "Ops", :zero)
    assert %{kind: :defp} = find(defs, "Ops", :double)
    assert %{kind: :defmacro} = find(defs, "Ops", :twice)
  end

  test "treats function captures as call sites" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")
    all = find(defs, "Ops", :all)

    assert %{range: %{start: {5, 22}, end: {5, 30}}} = site(all, 5, 27)
    assert %{range: %{start: {5, 38}, end: {5, 44}}} = site(all, 5, 38)
  end

  test "returns the parser error for invalid source" do
    assert {:error, _} = Extract.extract("defmodule Broken do\n  def (\nend\n", "lib/broken.ex")
  end

  defp find(defs, module, name), do: Enum.find(defs, &(&1.module == module and &1.name == name))
  defp site(def, line, column), do: Enum.find(def.call_sites, &(&1.line == line and &1.column == column))
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd grasp_index && mix test test/grasp/index/extract_test.exs`
Expected: `Grasp.Index.Extract` undefined.

- [ ] **Step 3: Implement extraction**

`grasp_index/lib/grasp/index/extract.ex`:

```elixir
defmodule Grasp.Index.Extract do
  @moduledoc """
  Reads one Elixir source file with Sourceror and returns its function definitions and
  the call sites inside them.

  A definition groups every clause of a `{module, name, arity}` — including the extra
  arities a head with default arguments introduces — into one record whose span runs
  from the first attached attribute (`@doc`, `@spec`, `@impl`, `@deprecated`, `@since`)
  or leading comment through the last clause's end. Module names come from the
  `defmodule` nesting, including `__MODULE__.Sub` heads; a `defmodule` whose name is
  not a literal alias is skipped. Call sites are every call node in a clause, keyed by
  the position the compiler reports for that call — the line and column of the function
  name — so `Grasp.Index.Join` can pair them with tracer events. A site's range covers
  the callee only (`Formatter.wrap`, `shout`, `double`), never its arguments, so ranges
  don't nest when rendered.
  """

  @type range :: %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}}
  @type call_site :: %{line: pos_integer(), column: pos_integer(), range: range()}
  @type kind :: :def | :defp | :defmacro | :defmacrop | :defguard | :defguardp | :defdelegate

  @type definition :: %{
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: kind(),
          file: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          source: String.t(),
          call_sites: [call_site()]
        }

  @type module_info :: %{name: String.t(), file: String.t(), line: pos_integer()}

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @attached_attributes [:doc, :spec, :impl, :deprecated, :since]
  @not_calls [:__block__, :__aliases__, :., :fn, :->, :__MODULE__]

  @doc "Parses `source`, read from the project-relative `file`, into definitions and modules."
  @spec extract(String.t(), String.t()) ::
          {:ok, %{definitions: [definition()], modules: [module_info()]}} | {:error, term()}
  def extract(source, file) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      lines = String.split(source, "\n")
      acc = walk(ast, [], %{definitions: [], modules: [], lines: lines, file: file})
      {:ok, %{definitions: Enum.reverse(acc.definitions), modules: Enum.reverse(acc.modules)}}
    end
  end

  defp walk({:defmodule, meta, [name_ast, body]}, stack, acc) do
    case module_name(name_ast, stack) do
      nil ->
        acc

      name ->
        parts = String.split(name, ".")
        acc = %{acc | modules: [%{name: name, file: acc.file, line: meta[:line]} | acc.modules]}
        body |> do_block_exprs() |> collect_definitions(name, parts, acc)
    end
  end

  defp walk({:__block__, _, exprs}, stack, acc), do: Enum.reduce(exprs, acc, &walk(&1, stack, &2))
  defp walk(_other, _stack, acc), do: acc

  defp module_name({:__aliases__, _, [:Elixir | parts]}, _stack), do: join_alias(parts, [])
  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, stack), do: join_alias(parts, stack)
  defp module_name({:__aliases__, _, parts}, stack), do: join_alias(parts, stack)
  defp module_name(_dynamic, _stack), do: nil

  defp join_alias(parts, stack) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.join(stack ++ Enum.map(parts, &Atom.to_string/1), ".")
    end
  end

  defp do_block_exprs([{{:__block__, _, [:do]}, {:__block__, _, exprs}} | _]), do: exprs
  defp do_block_exprs([{{:__block__, _, [:do]}, expr} | _]), do: [expr]
  defp do_block_exprs(_), do: []

  # Walks a module body in order, carrying the attributes that will attach to the next
  # definition; anything that is neither an attached attribute nor a definition resets them.
  defp collect_definitions(exprs, module, parts, acc) do
    {acc, _pending} =
      Enum.reduce(exprs, {acc, []}, fn
        {:@, _, [{attr, _, _}]} = node, {acc, pending} when attr in @attached_attributes ->
          {acc, pending ++ [node]}

        {kind, _, [head | _]} = node, {acc, pending} when kind in @def_kinds ->
          {add_clause(acc, module, kind, head, node, pending), []}

        {:defmodule, _, _} = node, {acc, _pending} ->
          {walk(node, parts, acc), []}

        _other, {acc, _pending} ->
          {acc, []}
      end)

    acc
  end

  defp add_clause(acc, module, kind, head, node, pending) do
    case head_signature(head) do
      nil ->
        acc

      {name, arity, arities} ->
        first = List.first(pending) || node
        %{start: [line: start_line, column: _]} = Sourceror.get_range(first, include_comments: true)
        %{end: [line: end_line, column: _]} = Sourceror.get_range(node)
        sites = call_sites(node)

        clause = %{
          module: module,
          name: name,
          arity: arity,
          arities: arities,
          kind: kind,
          file: acc.file,
          start_line: start_line,
          end_line: end_line,
          source: nil,
          call_sites: sites
        }

        %{acc | definitions: merge_clause(acc.definitions, clause, acc.lines)}
    end
  end

  defp merge_clause(definitions, clause, lines) do
    key = {clause.module, clause.name, clause.arity}

    case Enum.split_with(definitions, &({&1.module, &1.name, &1.arity} == key)) do
      {[existing], rest} ->
        merged = %{
          existing
          | start_line: min(existing.start_line, clause.start_line),
            end_line: max(existing.end_line, clause.end_line),
            arities: Enum.uniq(Enum.sort(existing.arities ++ clause.arities)),
            call_sites: existing.call_sites ++ clause.call_sites
        }

        [with_source(merged, lines) | rest]

      {[], rest} ->
        [with_source(clause, lines) | rest]
    end
  end

  defp with_source(definition, lines) do
    source =
      lines
      |> Enum.slice(definition.start_line - 1, definition.end_line - definition.start_line + 1)
      |> Enum.join("\n")

    %{definition | source: source}
  end

  defp head_signature({:when, _, [head, _guard]}), do: head_signature(head)

  defp head_signature({name, _, args}) when is_atom(name) and (is_list(args) or is_nil(args)) do
    args = args || []
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, [_, _]}, &1))
    {name, arity, Enum.to_list((arity - defaults)..arity//1)}
  end

  defp head_signature(_dynamic), do: nil

  # The head is never a call site: the compiler reports a `Module.compile_definition_attributes/6`
  # event at the head's position, and without this exclusion it would land on the function name.
  # Guards are searched because custom guards (`when is_pos(x)`) are real calls.
  defp call_sites({_kind, _meta, [head | rest]}) do
    searched =
      case head do
        {:when, _, [_head, guard]} -> [guard | rest]
        _ -> rest
      end

    {_, sites} =
      Macro.prewalk(searched, [], fn
        {:&, _, [{:/, _, [target, _arity]}]} = node, sites ->
          {node, add_site(sites, target)}

        {{:., _, _}, _, args} = node, sites when is_list(args) ->
          {node, add_site(sites, node)}

        {name, _, args} = node, sites when is_atom(name) and is_list(args) and name not in @not_calls ->
          {node, add_site(sites, node)}

        node, sites ->
          {node, sites}
      end)

    sites |> Enum.reverse() |> Enum.uniq_by(&{&1.line, &1.column})
  end

  defp add_site(sites, node) do
    case call_range(node) do
      nil -> sites
      {line, column, range} -> [%{line: line, column: column, range: range} | sites]
    end
  end

  # Remote call: the compiler reports the function name's position; the range starts at
  # the receiver when it is a literal alias/atom (`Formatter.wrap`) and at the name
  # otherwise (`foo().bar`), so nothing but the callee gets wrapped.
  defp call_range({{:., _, [receiver, name]}, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line], column when is_integer(column) <- meta[:column] do
      start =
        case receiver do
          {:__aliases__, alias_meta, _} -> {alias_meta[:line], alias_meta[:column]}
          {:__block__, atom_meta, [atom]} when is_atom(atom) -> {atom_meta[:line], atom_meta[:column]}
          _expression -> {line, column}
        end

      {line, column, %{start: start, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range({name, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line], column when is_integer(column) <- meta[:column] do
      {line, column, %{start: {line, column}, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range(_other), do: nil
end
```

- [ ] **Step 4: Run the tests and reconcile positions**

Run: `cd grasp_index && mix test test/grasp/index/extract_test.exs`
Expected: 6 tests, 0 failures.

If a call-site column assertion fails, inspect the actual `call_sites` list for that definition and compare against the source: the site's `column` must be the column of the function name (`wrap` is column 22 on line 6 of `@source`; `double` is column 38 on line 5 of `@kinds`). Fix the extraction, not the expected numbers, unless you miscounted the source.

- [ ] **Step 5: Format and commit**

```bash
cd ~/repos/grasp/grasp_index && mix format && cd .. && git add -A && git commit -m "Extract definitions and call sites from source with Sourceror

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Join events to definitions

**Files:**
- Create: `grasp_index/lib/grasp/index/join.ex`
- Test: `grasp_index/test/grasp/index/join_test.exs`

**Interfaces:**
- Consumes: `Grasp.Index.Extract.definition()`, `Grasp.Index.Tracer.event()`.
- Produces:
  - `Grasp.Index.Join.join([definition()], [event()]) :: [function_record()]`
  - `Grasp.Index.Join.function_id(module :: module() | String.t(), name :: atom(), arity :: non_neg_integer()) :: String.t()`
  - `function_record() :: %{id: String.t(), module: String.t(), name: atom(), arity: non_neg_integer(), arities: [non_neg_integer()], kind: Extract.kind(), file: String.t(), span: %{start_line: pos_integer(), end_line: pos_integer()}, source: String.t(), calls: [call()], hidden_calls: [hidden_call()]}`
  - `call() :: %{target: String.t(), kind: Tracer.kind(), range: Extract.range()}`
  - `hidden_call() :: %{target: String.t(), kind: Tracer.kind(), line: pos_integer()}`

- [ ] **Step 1: Write the failing tests**

`grasp_index/test/grasp/index/join_test.exs`:

```elixir
defmodule Grasp.Index.JoinTest do
  use ExUnit.Case, async: false

  alias Grasp.Index.{Extract, Join}
  alias Grasp.TestSupport.Compile

  @source ~S"""
  defmodule Grasp.JoinTest.Sample do
    alias Enum, as: E
    import String, only: [upcase: 1]

    def run(list, extra \\ nil) do
      E.map(list, &helper/1)
      upcase("a")
      helper(extra)
    end

    defp helper(x), do: x
  end
  """

  setup do
    events = Compile.trace(@source, "lib/sample.ex")
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    %{events: events, defs: defs}
  end

  test "function_id/3 formats Elixir and Erlang modules", _ do
    assert Join.function_id(Grasp.JoinTest.Sample, :run, 2) == "Grasp.JoinTest.Sample.run/2"
    assert Join.function_id(:erlang, :max, 2) == ":erlang.max/2"
    assert Join.function_id("Grasp.JoinTest.Sample", :run, 2) == "Grasp.JoinTest.Sample.run/2"
  end

  test "pairs events with call sites into ranged calls", %{events: events, defs: defs} do
    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.id == "Grasp.JoinTest.Sample.run/2"
    assert run.arities == [1, 2]
    assert run.span == %{start_line: 5, end_line: 9}

    assert %{kind: :remote, range: %{start: {6, 5}, end: {6, 10}}} = call(run, "Enum.map/2")
    assert %{kind: :local, range: %{start: {6, 18}, end: {6, 24}}} = call(run, "Grasp.JoinTest.Sample.helper/1")
    assert %{kind: :imported, range: %{start: {7, 5}, end: {7, 11}}} = call(run, "String.upcase/1")
    assert run.hidden_calls == []
  end

  test "drops Kernel calls, def-registration events and events without a column", %{defs: defs} do
    events = [
      event(:run, 2, 6, 7, {Kernel, :if, 2}, :imported_macro),
      event(:run, 2, 6, nil, {:erlang, :orelse, 2}, :remote),
      event(:run, 2, 5, 7, {Module, :compile_definition_attributes, 6}, :remote)
    ]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))
    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "keeps events with no matching node as hidden calls", %{defs: defs} do
    events = [event(:run, 2, 6, 99, {MyAppWeb.CoreComponents, :button, 1}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))
    assert run.hidden_calls == [%{target: "MyAppWeb.CoreComponents.button/1", kind: :remote, line: 6}]
  end

  test "attributes events made through a default-argument arity to the definition", %{defs: defs} do
    events = [event(:run, 1, 6, 7, {Enum, :map, 2}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))
    assert [%{target: "Enum.map/2"}] = run.calls
  end

  test "drops events whose caller has no definition", %{defs: defs} do
    events = [event(:generated, 0, 6, 7, {Enum, :map, 2}, :remote)]
    assert Enum.all?(Join.join(defs, events), &(&1.calls == [] and &1.hidden_calls == []))
  end

  defp call(record, target), do: Enum.find(record.calls, &(&1.target == target))

  defp event(name, arity, line, column, target, kind) do
    %{
      file: "lib/sample.ex",
      module: Grasp.JoinTest.Sample,
      function: {name, arity},
      line: line,
      column: column,
      target: target,
      kind: kind
    }
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd grasp_index && mix test test/grasp/index/join_test.exs`
Expected: `Grasp.Index.Join` undefined.

- [ ] **Step 3: Implement the join**

`grasp_index/lib/grasp/index/join.ex`:

```elixir
defmodule Grasp.Index.Join do
  @moduledoc """
  Pairs compiler tracer events with the definitions Sourceror extracted, producing the
  function records the index stores.

  An event is attributed to the definition whose module, name and arity match the caller
  the compiler reported; a definition registers every arity its default arguments
  introduce, so calls made through any of them land on it. The event's line and column
  then locate the call node inside that definition. Events with no column are compiler
  bookkeeping (`def` registration, boolean operators expanded from `if`) rather than
  user code and are dropped, as are calls into `Kernel` and `Kernel.SpecialForms`. An
  event with a column but no matching node came from macro-generated code — a function
  component in a `~H` template, code injected by `use` — and is kept as a hidden call so
  the graph stays complete even though nothing in the source can be clicked.
  """

  alias Grasp.Index.{Extract, Tracer}

  @ignored_targets [Kernel, Kernel.SpecialForms, Kernel.Utils]
  # Emitted by the compiler at every def head while it registers the definition.
  @ignored_calls [{Module, :compile_definition_attributes, 6}]

  @type call :: %{target: String.t(), kind: Tracer.kind(), range: Extract.range()}
  @type hidden_call :: %{target: String.t(), kind: Tracer.kind(), line: pos_integer()}

  @type function_record :: %{
          id: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: Extract.kind(),
          file: String.t(),
          span: %{start_line: pos_integer(), end_line: pos_integer()},
          source: String.t(),
          calls: [call()],
          hidden_calls: [hidden_call()]
        }

  @doc "Builds the `\"Module.name/arity\"` id; `module` may be an atom or its `inspect/1` form."
  @spec function_id(module() | String.t(), atom(), non_neg_integer()) :: String.t()
  def function_id(module, name, arity) when is_atom(module), do: function_id(inspect(module), name, arity)
  def function_id(module, name, arity) when is_binary(module), do: "#{module}.#{name}/#{arity}"

  @doc "Turns definitions and tracer events into function records with resolved calls."
  @spec join([Extract.definition()], [Tracer.event()]) :: [function_record()]
  def join(definitions, events) do
    canonical =
      for definition <- definitions, arity <- definition.arities, into: %{} do
        {{definition.module, definition.name, arity}, {definition.module, definition.name, definition.arity}}
      end

    events_by_definition =
      events
      |> Enum.filter(&keep?/1)
      |> Enum.group_by(fn event ->
        {name, arity} = event.function
        Map.get(canonical, {inspect(event.module), name, arity})
      end)

    Enum.map(definitions, fn definition ->
      key = {definition.module, definition.name, definition.arity}
      build(definition, Map.get(events_by_definition, key, []))
    end)
  end

  defp keep?(%{column: nil}), do: false
  defp keep?(%{target: {module, _, _}}) when module in @ignored_targets, do: false
  defp keep?(%{target: target}) when target in @ignored_calls, do: false
  defp keep?(_event), do: true

  defp build(definition, events) do
    sites = Map.new(definition.call_sites, &{{&1.line, &1.column}, &1.range})

    {calls, hidden} =
      Enum.reduce(events, {[], []}, fn event, {calls, hidden} ->
        {module, name, arity} = event.target
        target = function_id(module, name, arity)

        case Map.fetch(sites, {event.line, event.column}) do
          {:ok, range} -> {[%{target: target, kind: event.kind, range: range} | calls], hidden}
          :error -> {calls, [%{target: target, kind: event.kind, line: event.line} | hidden]}
        end
      end)

    %{
      id: function_id(definition.module, definition.name, definition.arity),
      module: definition.module,
      name: definition.name,
      arity: definition.arity,
      arities: definition.arities,
      kind: definition.kind,
      file: definition.file,
      span: %{start_line: definition.start_line, end_line: definition.end_line},
      source: definition.source,
      calls: calls |> Enum.uniq() |> Enum.sort_by(& &1.range.start),
      hidden_calls: hidden |> Enum.uniq() |> Enum.sort_by(& &1.line)
    }
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd grasp_index && mix test test/grasp/index/join_test.exs`
Expected: 6 tests, 0 failures. Then run the whole suite: `mix test` — all green.

- [ ] **Step 5: Format and commit**

```bash
cd ~/repos/grasp/grasp_index && mix format && cd .. && git add -A && git commit -m "Join tracer events with extracted definitions into function records

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Index reader

**Files:**
- Create: `grasp_index/lib/grasp/index.ex`
- Test: `grasp_index/test/grasp/index_test.exs`

**Interfaces:**
- Consumes: the JSON document shape (string keys) written in Task 6. Function records in the document have keys `"id" "module" "name" "arity" "arities" "kind" "file" "span" "source" "calls" "hidden_calls" "change" "base_source" "removed"`.
- Produces `Grasp.Index` struct and:
  - `load(path) :: {:ok, t()} | {:error, term()}`, `from_document(map()) :: t()`
  - `fetch_function(t(), id) :: {:ok, map()} | :error` (resolves default-arity aliases)
  - `callers(t(), id) :: [String.t()]`, `callees(t(), id) :: [String.t()]` (sorted, unique, alias-resolved)
  - `search(t(), query, limit \\ 20) :: [map()]`
  - `modules(t()) :: [map()]`, `entry_points(t()) :: [map()]`, `changed_functions(t()) :: [map()]`, `functions(t()) :: [map()]`

- [ ] **Step 1: Write the failing tests**

`grasp_index/test/grasp/index_test.exs`:

```elixir
defmodule Grasp.IndexTest do
  use ExUnit.Case, async: true

  alias Grasp.Index

  @document %{
    "version" => 1,
    "generated_at" => "2026-09-15T10:00:00Z",
    "project" => %{"app" => "my_app", "root" => "/tmp/my_app", "elixirc_paths" => ["lib"]},
    "git" => nil,
    "modules" => [%{"name" => "MyApp.Wallets", "file" => "lib/my_app/wallets.ex", "line" => 1}],
    "entry_points" => [],
    "functions" => [
      function("MyApp.Wallets.credit/3", "MyApp.Wallets", "credit", 3, [2, 3], [
        %{"target" => "MyApp.Ledger.post/2", "kind" => "remote", "range" => %{"start" => [10, 5], "end" => [10, 16]}}
      ]),
      function("MyApp.Wallets.debit/3", "MyApp.Wallets", "debit", 3, [3], []),
      function("MyAppWeb.WalletController.create/2", "MyAppWeb.WalletController", "create", 2, [2], [
        %{"target" => "MyApp.Wallets.credit/2", "kind" => "remote", "range" => %{"start" => [8, 5], "end" => [8, 19]}}
      ], [%{"target" => "MyApp.Wallets.debit/3", "kind" => "remote", "line" => 12}]),
      Map.put(function("MyApp.Ledger.post/2", "MyApp.Ledger", "post", 2, [2], []), "change", "modified")
    ]
  }

  defp function(id, module, name, arity, arities, calls, hidden \\ []) do
    %{
      "id" => id, "module" => module, "name" => name, "arity" => arity, "arities" => arities,
      "kind" => "def", "file" => "lib/x.ex", "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def #{name}", "calls" => calls, "hidden_calls" => hidden,
      "change" => "unchanged", "base_source" => nil, "removed" => false
    }
  end

  setup do
    %{index: Index.from_document(@document)}
  end

  test "fetch_function/2 finds by canonical id and by default-argument arity", %{index: index} do
    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} = Index.fetch_function(index, "MyApp.Wallets.credit/3")
    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} = Index.fetch_function(index, "MyApp.Wallets.credit/2")
    assert :error = Index.fetch_function(index, "MyApp.Wallets.credit/9")
  end

  test "callers/2 inverts calls and hidden calls, resolving aliases", %{index: index} do
    assert Index.callers(index, "MyApp.Wallets.credit/3") == ["MyAppWeb.WalletController.create/2"]
    assert Index.callers(index, "MyApp.Wallets.debit/3") == ["MyAppWeb.WalletController.create/2"]
    assert Index.callers(index, "MyApp.Ledger.post/2") == ["MyApp.Wallets.credit/3"]
    assert Index.callers(index, "Nobody.calls/0") == []
  end

  test "callees/2 lists resolved targets including hidden calls", %{index: index} do
    assert Index.callees(index, "MyAppWeb.WalletController.create/2") == ["MyApp.Wallets.credit/3", "MyApp.Wallets.debit/3"]
    assert Index.callees(index, "MyApp.Wallets.credit/2") == ["MyApp.Ledger.post/2"]
  end

  test "search/3 ranks exact, then substring, then subsequence matches", %{index: index} do
    assert ids(Index.search(index, "MyApp.Wallets.debit/3")) == ["MyApp.Wallets.debit/3"]
    assert ids(Index.search(index, "credit")) == ["MyApp.Wallets.credit/3"]
    assert ["MyApp.Wallets.credit/3" | _] = ids(Index.search(index, "walcre"))
    assert ids(Index.search(index, "wallets")) == ["MyApp.Wallets.debit/3", "MyApp.Wallets.credit/3"]
    assert ids(Index.search(index, "wallet")) == ["MyApp.Wallets.debit/3", "MyApp.Wallets.credit/3", "MyAppWeb.WalletController.create/2"]
    assert Index.search(index, "zzzzzz") == []
    assert Index.search(index, "   ") == []
    assert length(Index.search(index, "a", 2)) == 2
  end

  test "changed_functions/1 returns everything not unchanged", %{index: index} do
    assert ids(Index.changed_functions(index)) == ["MyApp.Ledger.post/2"]
  end

  test "load/1 reads a document from disk", %{index: index} do
    path = Path.join(System.tmp_dir!(), "grasp-index-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(@document))

    assert {:ok, loaded} = Index.load(path)
    assert Index.functions(loaded) == Index.functions(index)
    assert Index.modules(loaded) == [%{"name" => "MyApp.Wallets", "file" => "lib/my_app/wallets.ex", "line" => 1}]
    assert {:error, _} = Index.load(path <> ".missing")
  end

  defp ids(records), do: Enum.map(records, & &1["id"])
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd grasp_index && mix test test/grasp/index_test.exs`
Expected: `Grasp.Index` undefined.

- [ ] **Step 3: Implement the reader**

`grasp_index/lib/grasp/index.ex`:

```elixir
defmodule Grasp.Index do
  @moduledoc """
  In-memory view of an index document written by `mix grasp.index`.

  Records keep the document's string keys so the viewer and the MCP server render the
  same shape they would read from disk. Functions are keyed by id (`"Mod.fun/arity"`);
  a definition with default arguments is also reachable through each extra arity it
  defines. Callers are derived at load time by inverting every function's calls and
  hidden calls. Search ranks an exact id first, then ids containing the query, then ids
  whose characters contain the query as a subsequence, so `"walcre"` still finds
  `MyApp.Wallets.credit/3`.
  """

  defstruct version: 1,
            generated_at: nil,
            project: %{},
            git: nil,
            modules: [],
            entry_points: [],
            functions: %{},
            aliases: %{},
            callers: %{}

  @type function_record :: %{required(String.t()) => term()}
  @type t :: %__MODULE__{
          version: pos_integer(),
          generated_at: String.t() | nil,
          project: map(),
          git: map() | nil,
          modules: [map()],
          entry_points: [map()],
          functions: %{String.t() => function_record()},
          aliases: %{String.t() => String.t()},
          callers: %{String.t() => [String.t()]}
        }

  @doc "Reads and decodes an index document from `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, document} <- Jason.decode(binary) do
      {:ok, from_document(document)}
    end
  end

  @doc "Builds the index from a decoded document (string keys)."
  @spec from_document(map()) :: t()
  def from_document(%{"version" => 1, "functions" => records} = document) do
    functions = Map.new(records, &{&1["id"], &1})

    aliases =
      for record <- records, arity <- record["arities"], into: %{} do
        {"#{record["module"]}.#{record["name"]}/#{arity}", record["id"]}
      end

    callers =
      records
      |> Enum.flat_map(fn record ->
        for call <- record["calls"] ++ record["hidden_calls"] do
          {Map.get(aliases, call["target"], call["target"]), record["id"]}
        end
      end)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {target, callers} -> {target, Enum.sort(callers)} end)

    %__MODULE__{
      version: 1,
      generated_at: document["generated_at"],
      project: document["project"] || %{},
      git: document["git"],
      modules: document["modules"] || [],
      entry_points: document["entry_points"] || [],
      functions: functions,
      aliases: aliases,
      callers: callers
    }
  end

  @doc "Fetches a function by id, following default-argument arities to the definition."
  @spec fetch_function(t(), String.t()) :: {:ok, function_record()} | :error
  def fetch_function(%__MODULE__{} = index, id), do: Map.fetch(index.functions, resolve(index, id))

  @doc "Ids of the functions that call `id`, sorted."
  @spec callers(t(), String.t()) :: [String.t()]
  def callers(%__MODULE__{} = index, id), do: Map.get(index.callers, resolve(index, id), [])

  @doc "Ids the function calls (visible and hidden), resolved and sorted."
  @spec callees(t(), String.t()) :: [String.t()]
  def callees(%__MODULE__{} = index, id) do
    case fetch_function(index, id) do
      {:ok, record} ->
        (record["calls"] ++ record["hidden_calls"])
        |> Enum.map(&resolve(index, &1["target"]))
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @doc "All function records, sorted by id."
  @spec functions(t()) :: [function_record()]
  def functions(%__MODULE__{} = index), do: index.functions |> Map.values() |> Enum.sort_by(& &1["id"])

  @doc "Module records as stored in the document."
  @spec modules(t()) :: [map()]
  def modules(%__MODULE__{} = index), do: index.modules

  @doc "Entry-point records as stored in the document."
  @spec entry_points(t()) :: [map()]
  def entry_points(%__MODULE__{} = index), do: index.entry_points

  @doc "Functions whose `change` is anything but `\"unchanged\"`, sorted by id."
  @spec changed_functions(t()) :: [function_record()]
  def changed_functions(%__MODULE__{} = index) do
    index |> functions() |> Enum.reject(&(&1["change"] == "unchanged"))
  end

  @doc """
  Ranks functions against `query`: exact id, then ids containing it, then ids containing
  it as a subsequence. Case-insensitive; shorter ids win ties.
  """
  @spec search(t(), String.t(), pos_integer()) :: [function_record()]
  def search(%__MODULE__{} = index, query, limit \\ 20) do
    query = query |> String.trim() |> String.downcase()

    if query == "" do
      []
    else
      index.functions
      |> Map.values()
      |> Enum.flat_map(fn record ->
        case score(String.downcase(record["id"]), query) do
          nil -> []
          score -> [{score, record}]
        end
      end)
      |> Enum.sort_by(fn {score, record} -> {-score, String.length(record["id"]), record["id"]} end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp resolve(%__MODULE__{} = index, id), do: Map.get(index.aliases, id, id)

  defp score(id, query) do
    cond do
      id == query -> 3
      String.contains?(id, query) -> 2
      subsequence?(String.graphemes(id), String.graphemes(query)) -> 1
      true -> nil
    end
  end

  defp subsequence?(_haystack, []), do: true
  defp subsequence?([], _needle), do: false
  defp subsequence?([char | rest], [char | needle]), do: subsequence?(rest, needle)
  defp subsequence?([_ | rest], needle), do: subsequence?(rest, needle)
end
```

- [ ] **Step 4: Run the tests**

Run: `cd grasp_index && mix test test/grasp/index_test.exs`
Expected: 6 tests, 0 failures.

- [ ] **Step 5: Format and commit**

```bash
cd ~/repos/grasp/grasp_index && mix format && cd .. && git add -A && git commit -m "Add Grasp.Index reader with alias-aware lookups, callers and search

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Builder, mix task, fixture app and integration test

**Files:**
- Create: `grasp_index/lib/grasp/index/builder.ex`, `grasp_index/lib/mix/tasks/grasp.index.ex`
- Create fixture: `grasp_index/test/fixtures/sample_app/mix.exs`, `grasp_index/test/fixtures/sample_app/lib/sample_app/greeter.ex`, `grasp_index/test/fixtures/sample_app/lib/sample_app/formatter.ex`
- Test: `grasp_index/test/grasp/index/builder_test.exs`

**Interfaces:**
- Consumes: `Grasp.Index.Tracer`, `Grasp.Index.Extract.extract/2`, `Grasp.Index.Join.join/2` and `function_id/3`, `Grasp.Index.load/1`.
- Produces: `Grasp.Index.Builder.run(opts :: [out: String.t()]) :: {:ok, %{path: String.t(), functions: non_neg_integer(), calls: non_neg_integer(), hidden_calls: non_neg_integer()}}` and the `mix grasp.index [--out PATH]` task. Must be called inside a Mix project (`Mix.Project.config/0` available).

- [ ] **Step 1: Create the fixture project**

`grasp_index/test/fixtures/sample_app/mix.exs`:

```elixir
defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:grasp_index, path: "../../..", only: :dev, runtime: false}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
```

`grasp_index/test/fixtures/sample_app/lib/sample_app/formatter.ex`:

```elixir
defmodule SampleApp.Formatter do
  @moduledoc "String decorations used by the greeter."

  @doc "Wraps text in brackets."
  @spec wrap(String.t()) :: String.t()
  def wrap(text), do: "[" <> text <> "]"

  @doc "Upcases text and adds an exclamation mark."
  @spec shout(String.t()) :: String.t()
  def shout(text), do: String.upcase(text) <> "!"
end
```

`grasp_index/test/fixtures/sample_app/lib/sample_app/greeter.ex` (line numbers matter for the test; keep exactly this layout):

```elixir
defmodule SampleApp.Greeter do
  @moduledoc "Greets people, exercising aliases, imports, defaults, captures and nesting."
  alias SampleApp.Formatter
  import SampleApp.Formatter, only: [shout: 1]

  @doc "Greets someone, loudly if asked."
  @spec greet(String.t(), boolean()) :: String.t()
  def greet(name, loud? \\ false) do
    text = Formatter.wrap(name)
    if loud?, do: shout(text), else: text
  end

  @doc "Greets everyone."
  @spec greet_all([String.t()]) :: [String.t()]
  def greet_all(names), do: Enum.map(names, &greet/1)

  defmodule Nested do
    @moduledoc "A nested module calling back into its parent."

    @doc "Greets from inside."
    @spec hello() :: String.t()
    def hello, do: SampleApp.Greeter.greet("nested")
  end
end
```

Also create `grasp_index/test/fixtures/sample_app/.formatter.exs` with `[inputs: ["{mix,.formatter}.exs", "lib/**/*.ex"]]`.

- [ ] **Step 2: Write the failing integration test**

`grasp_index/test/grasp/index/builder_test.exs`:

```elixir
defmodule Grasp.Index.BuilderTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)

  setup_all do
    out = Path.join(System.tmp_dir!(), "grasp-sample-#{System.unique_integer([:positive])}.json")
    env = [{"MIX_ENV", "dev"}]

    unless File.dir?(Path.join(@fixture, "deps/sourceror")) do
      {_, 0} = System.cmd("mix", ["deps.get"], cd: @fixture, env: env, stderr_to_stdout: true)
    end

    {output, status} =
      System.cmd("mix", ["grasp.index", "--out", out], cd: @fixture, env: env, stderr_to_stdout: true)

    assert status == 0, output
    {:ok, index} = Grasp.Index.load(out)
    %{index: index, output: output}
  end

  test "reports what it wrote", %{output: output} do
    assert output =~ ~r/Grasp index written to .*grasp-sample-\d+\.json \(\d+ functions, \d+ calls, \d+ hidden\)/
  end

  test "records project metadata", %{index: index} do
    assert index.project["app"] == "sample_app"
    assert index.project["elixirc_paths"] == ["lib"]
    assert index.project["root"] == @fixture
    assert is_binary(index.generated_at)
  end

  test "indexes definitions with spans, sources and default arities", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert greet["arities"] == [1, 2]
    assert greet["kind"] == "def"
    assert greet["file"] == "lib/sample_app/greeter.ex"
    assert greet["span"] == %{"start_line" => 6, "end_line" => 11}
    assert String.starts_with?(greet["source"], "  @doc \"Greets someone")
    assert greet["change"] == "unchanged"
    assert greet["removed"] == false
  end

  test "resolves aliased, imported, local, captured and nested calls with ranges", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert %{"kind" => "remote", "range" => %{"start" => [9, 12], "end" => [9, 26]}} =
             call(greet, "SampleApp.Formatter.wrap/1")

    assert %{"kind" => "imported", "range" => %{"start" => [10, 19], "end" => [10, 24]}} =
             call(greet, "SampleApp.Formatter.shout/1")

    {:ok, greet_all} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet_all/1")
    assert %{"kind" => "remote"} = call(greet_all, "Enum.map/2")
    assert %{"kind" => "local", "range" => %{"start" => [15, 46], "end" => [15, 51]}} =
             call(greet_all, "SampleApp.Greeter.greet/1")

    assert Grasp.Index.callers(index, "SampleApp.Greeter.greet/2") ==
             ["SampleApp.Greeter.Nested.hello/0", "SampleApp.Greeter.greet_all/1"]
  end

  test "lists modules including nested ones", %{index: index} do
    names = index |> Grasp.Index.modules() |> Enum.map(& &1["name"])
    assert "SampleApp.Greeter" in names
    assert "SampleApp.Greeter.Nested" in names
    assert "SampleApp.Formatter" in names
  end

  test "carries empty entry points until milestone 3", %{index: index} do
    assert Grasp.Index.entry_points(index) == []
  end

  defp call(record, target), do: Enum.find(record["calls"], &(&1["target"] == target))
end
```

Column check for line 15 of `greeter.ex`, `  def greet_all(names), do: Enum.map(names, &greet/1)`: two spaces, `def` 3–5, space, `greet_all(names),` 7–23, space, `do:` 25–27, space, `Enum` 29–32, `.` 33, `map` 34–36, `(` 37, `names,` 38–43, space 44, `&` 45, `greet` 46–50, so the range is `[15, 46]`–`[15, 51]`. Verify against the file with `awk 'NR==15{print index($0,"&greet")+1}'` (expect 46) before trusting the assertion. Do the same check for line 9 (`Formatter` at 12, `wrap` ends at 26 exclusive) and line 10 (`shout` at 19).

- [ ] **Step 3: Run to verify failure**

Run: `cd grasp_index && mix test test/grasp/index/builder_test.exs`
Expected: fails in `setup_all` — `mix grasp.index` is not a task yet (non-zero status, output says "The task "grasp.index" could not be found").

- [ ] **Step 4: Implement the builder**

`grasp_index/lib/grasp/index/builder.ex`:

```elixir
defmodule Grasp.Index.Builder do
  @moduledoc """
  Builds the index for the Mix project in the current directory and writes it as JSON.

  Runs inside the target project's Mix session (`mix grasp.index`), where the compiler,
  the project configuration and the compiled code are all at hand. It registers
  `Grasp.Index.Tracer`, forces a full recompile so every call in the project is traced
  (dependencies are compiled only if stale and filtered out by path), extracts
  definitions from every `.ex` file under `:elixirc_paths`, joins the two and writes the
  document `Grasp.Index.load/1` reads. Git metadata is best-effort: `nil` when the
  project is not in a repository or `git` is not installed.
  """

  alias Grasp.Index.{Extract, Join, Tracer}

  @type summary :: %{
          path: String.t(),
          functions: non_neg_integer(),
          calls: non_neg_integer(),
          hidden_calls: non_neg_integer()
        }

  @doc "Traces, extracts, joins and writes the index. `:out` defaults to `.grasp/index.json`."
  @spec run(out: String.t()) :: {:ok, summary()}
  def run(opts) do
    out = Keyword.get(opts, :out, ".grasp/index.json")
    config = Mix.Project.config()
    root = File.cwd!()
    paths = Keyword.get(config, :elixirc_paths, ["lib"])

    events = trace_compile(root, paths)
    {definitions, modules} = extract_all(root, paths)
    functions = Join.join(definitions, events)

    document = %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "project" => %{"app" => to_string(config[:app]), "root" => root, "elixirc_paths" => paths},
      "git" => git_info(root),
      "modules" => Enum.map(modules, &%{"name" => &1.name, "file" => &1.file, "line" => &1.line}),
      "functions" => Enum.map(functions, &function_json/1),
      "entry_points" => []
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Jason.encode!(document, pretty: true))

    {:ok,
     %{
       path: out,
       functions: length(functions),
       calls: functions |> Enum.map(&length(&1.calls)) |> Enum.sum(),
       hidden_calls: functions |> Enum.map(&length(&1.hidden_calls)) |> Enum.sum()
     }}
  end

  defp trace_compile(root, paths) do
    previous_tracers = Code.get_compiler_option(:tracers)
    previous_parser = Code.get_compiler_option(:parser_options)
    Tracer.start()
    Code.put_compiler_option(:tracers, [Tracer | previous_tracers])
    Code.put_compiler_option(:parser_options, Keyword.put(previous_parser, :columns, true))

    try do
      Mix.Task.rerun("compile", ["--force"])
      roots = Enum.map(paths, &(Path.expand(&1, root) <> "/"))

      Tracer.events()
      |> Enum.map(&%{&1 | file: Path.expand(&1.file, root)})
      |> Enum.filter(fn event -> Enum.any?(roots, &String.starts_with?(event.file, &1)) end)
      |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, root)})
    after
      Code.put_compiler_option(:tracers, previous_tracers)
      Code.put_compiler_option(:parser_options, previous_parser)
      Tracer.stop()
    end
  end

  defp extract_all(root, paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.ex"])))
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn file, {definitions, modules} ->
      relative = Path.relative_to(file, root)

      case Extract.extract(File.read!(file), relative) do
        {:ok, extracted} ->
          {definitions ++ extracted.definitions, modules ++ extracted.modules}

        {:error, reason} ->
          Mix.shell().error("grasp: skipping #{relative}: #{inspect(reason)}")
          {definitions, modules}
      end
    end)
  end

  defp function_json(record) do
    %{
      "id" => record.id,
      "module" => record.module,
      "name" => Atom.to_string(record.name),
      "arity" => record.arity,
      "arities" => record.arities,
      "kind" => Atom.to_string(record.kind),
      "file" => record.file,
      "span" => %{"start_line" => record.span.start_line, "end_line" => record.span.end_line},
      "source" => record.source,
      "calls" =>
        Enum.map(record.calls, fn call ->
          %{
            "target" => call.target,
            "kind" => Atom.to_string(call.kind),
            "range" => %{"start" => Tuple.to_list(call.range.start), "end" => Tuple.to_list(call.range.end)}
          }
        end),
      "hidden_calls" =>
        Enum.map(record.hidden_calls, &%{"target" => &1.target, "kind" => Atom.to_string(&1.kind), "line" => &1.line}),
      "change" => "unchanged",
      "base_source" => nil,
      "removed" => false
    }
  end

  defp git_info(root) do
    with {head, 0} <- git(["rev-parse", "HEAD"], root),
         {branch, 0} <- git(["rev-parse", "--abbrev-ref", "HEAD"], root) do
      %{"head" => String.trim(head), "branch" => String.trim(branch), "base_ref" => nil, "base_sha" => nil}
    else
      _ -> nil
    end
  end

  defp git(args, root) do
    System.cmd("git", args, cd: root, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
```

`grasp_index/lib/mix/tasks/grasp.index.ex`:

```elixir
defmodule Mix.Tasks.Grasp.Index do
  @shortdoc "Writes a Grasp index of this project to .grasp/index.json"

  @moduledoc """
  Builds the Grasp index for the current Mix project.

      mix grasp.index [--out PATH]

  Forces a full recompile with a compiler tracer attached, so every call the compiler
  resolves is recorded with its position, then writes the JSON document the Grasp viewer
  and MCP server read.

  ## Options

    * `--out` - where to write the index. Defaults to `.grasp/index.json`.
  """

  use Mix.Task

  @switches [out: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.index: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    {:ok, summary} = Grasp.Index.Builder.run(opts)

    Mix.shell().info(
      "Grasp index written to #{summary.path} " <>
        "(#{summary.functions} functions, #{summary.calls} calls, #{summary.hidden_calls} hidden)"
    )
  end
end
```

- [ ] **Step 5: Run the integration test**

Run: `cd grasp_index && mix test test/grasp/index/builder_test.exs`
Expected: first run fetches the fixture's deps and compiles Sourceror (slow, under two minutes); 6 tests, 0 failures. If a range assertion fails, open the index JSON printed at `out` and check the actual range against the fixture file's columns as described in Step 2. Commit the fixture's generated `mix.lock` so runs are reproducible.

If `mix grasp.index` fails with "the task could not be found", the fixture did not pick up the path dep: run `mix deps.get` in the fixture and confirm `deps/grasp_index` is a symlink to the package.

- [ ] **Step 6: Run the whole suite, format, commit**

Run: `cd grasp_index && mix format && mix compile --warnings-as-errors && mix test`
Expected: all tests pass, no warnings.

```bash
cd ~/repos/grasp && git add -A && git commit -m "Add mix grasp.index: trace-compile, extract, join and write the index

Includes a fixture project exercising aliases, imports, defaults,
captures and nested modules, indexed end to end by an integration test.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Run against a real Phoenix project

**Files:**
- Modify (locally, do NOT commit): the target project's `mix.exs` deps.

**Interfaces:**
- Consumes: `mix grasp.index`.

- [ ] **Step 1: Point a real project at the package**

In a real Phoenix project on this machine, add to `deps/0`:

```elixir
{:grasp_index, path: "/Users/gigio/repos/grasp/grasp_index", only: :dev, runtime: false}
```

Run `mix deps.get` there. This edit is a local experiment: revert it with `git checkout -- mix.exs mix.lock` when done and never commit it to that repository.

- [ ] **Step 2: Index it**

Run in that project: `mix grasp.index`
Expected: a full recompile followed by `Grasp index written to .grasp/index.json (N functions, M calls, H hidden)` with N in the thousands for a real app. Note the wall-clock time.

- [ ] **Step 3: Spot-check a known chain**

Pick a controller action you know and check with `jq`:

```bash
jq '.functions[] | select(.id == "MyAppWeb.SomeController.show/2") | {span, calls: [.calls[].target], hidden: [.hidden_calls[].target]}' .grasp/index.json
```

Expected: the context functions the action calls appear in `calls` with ranges; function components used in a `~H` template appear in `hidden_calls`. Follow one target into the context module and confirm its `Repo` calls show up. Also check `jq '[.functions[] | select(.calls == [] and .hidden_calls == [])] | length'` is a plausible count of leaf functions, not the majority.

- [ ] **Step 4: Record findings**

Append a short "Tried on a real project" section to `grasp_index/README.md` only if something needed a workaround (e.g. a project setting `parser_options` in `elixirc_options`). Otherwise, no change. Revert the target project's `mix.exs`. Any bug found becomes a failing test in Tasks 2–6 first, then a fix, then a commit.

---

## Self-review

- **Spec coverage.** Part 1 steps 1, 2, 3, 6 → Tasks 2, 3, 4, 6. Index JSON shape → Task 6 `function_json/1` plus `Grasp.Index.from_document/1` in Task 5. Reader API (`load`, `fetch_function`, `callers`, `callees`, `search`, `entry_points`, `changed_functions`, `modules`) → Task 5. Steps 4 and 5 deliberately deferred; the JSON carries their fields with defaults so milestone 2 can build on a stable shape.
- **Type consistency.** `Extract.range()` is `{line, col}` tuples internally; `Builder.function_json/1` converts to `[line, col]` lists; `Grasp.Index` tests use lists. `Join.function_id/3` is the only place ids are formatted; `Grasp.Index.from_document/1` re-derives alias ids with the same `"#{module}.#{name}/#{arity}"` format from string fields. `Tracer.event().function` is always a 2-tuple because `trace/2` matches `%Macro.Env{function: {_, _}}`.
- **Known soft spots to watch during execution.** (1) Exact columns in the tracer/extract/builder tests were derived by counting source columns and by a probe on Elixir 1.20.4; if a column disagrees, verify against the source text before changing the assertion. (2) A definition whose clauses are interleaved with other definitions gets a span covering the lines in between; accepted for v1. (3) `defdelegate` may or may not produce a traced call for the delegated function; the tests don't assert on it.
