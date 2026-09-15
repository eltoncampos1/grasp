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

    assert %{kind: :local, range: %{start: {6, 18}, end: {6, 24}}} =
             call(run, "Grasp.JoinTest.Sample.helper/1")

    assert %{kind: :imported, range: %{start: {7, 5}, end: {7, 11}}} =
             call(run, "String.upcase/1")

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

    assert run.hidden_calls == [
             %{target: "MyAppWeb.CoreComponents.button/1", kind: :remote, line: 6}
           ]
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

  @hooked ~S"""
  defmodule Grasp.JoinTest.Hooks do
    def hook(_env, _kind, _name, _args, _guards, _body), do: :ok
  end

  defmodule Grasp.JoinTest.Hooked do
    @on_definition {Grasp.JoinTest.Hooks, :hook}

    def greet(name) do
      String.upcase(name)
    end
  end
  """

  test "drops the @on_definition hook reported at the def head and keeps the real call" do
    records = join_source(@hooked, "lib/hooked.ex")
    greet = record(records, "Grasp.JoinTest.Hooked", :greet)

    assert greet.calls == [
             %{target: "String.upcase/1", kind: :remote, range: %{start: {9, 5}, end: {9, 18}}}
           ]

    assert greet.hidden_calls == []
    assert record(records, "Grasp.JoinTest.Hooks", :hook).calls == []
  end

  @macros ~S"""
  defmodule Grasp.JoinTest.Macros do
    defmacro twice(x), do: quote(do: unquote(x) * 2)
  end
  """

  test "drops compiler internals reported inside a macro body" do
    twice = @macros |> join_source("lib/macros.ex") |> record("Grasp.JoinTest.Macros", :twice)
    targets = Enum.map(twice.calls ++ twice.hidden_calls, & &1.target)

    refute Enum.any?(targets, &String.starts_with?(&1, ":elixir_"))
    refute Enum.any?(targets, &String.contains?(&1, "unquote"))
  end

  @delegate ~S"""
  defmodule Grasp.JoinTest.Delegates do
    defdelegate size(x), to: Enum, as: :count
  end
  """

  test "recovers the delegated call of a defdelegate, ranged over the delegate name" do
    size =
      @delegate |> join_source("lib/delegates.ex") |> record("Grasp.JoinTest.Delegates", :size)

    assert size.calls == [
             %{target: "Enum.count/1", kind: :remote, range: %{start: {2, 15}, end: {2, 19}}}
           ]

    assert size.hidden_calls == []
  end

  @defaults ~S"""
  defmodule Grasp.JoinTest.Defaults do
    def greet(name, prefix \\ String.trim(" p ")) do
      prefix <> name
    end
  end
  """

  test "resolves a call inside a default argument to its expression, not a hidden call" do
    greet =
      @defaults |> join_source("lib/defaults.ex") |> record("Grasp.JoinTest.Defaults", :greet)

    assert greet.calls == [
             %{target: "String.trim/1", kind: :remote, range: %{start: {2, 29}, end: {2, 40}}}
           ]

    assert greet.hidden_calls == []
  end

  defp join_source(source, file) do
    events = Compile.trace(source, file)
    {:ok, %{definitions: defs}} = Extract.extract(source, file)
    Join.join(defs, events)
  end

  defp record(records, module, name),
    do: Enum.find(records, &(&1.module == module and &1.name == name))

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
