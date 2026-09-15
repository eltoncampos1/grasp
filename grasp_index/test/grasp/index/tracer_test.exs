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

    assert %{kind: :remote, line: 6, column: 7, target: {Enum, :map, 2}} =
             find(events, {Enum, :map, 2})

    assert %{kind: :local, line: 6, column: 18} =
             find(events, {Grasp.TracerTest.Sample, :helper, 1})

    assert %{kind: :imported, line: 7, column: 5, target: {String, :upcase, 1}} =
             find(events, {String, :upcase, 1})

    assert Enum.all?(events, &(&1.module == Grasp.TracerTest.Sample))
    assert Enum.all?(events, &(&1.file == "lib/sample.ex"))
  end

  test "attributes every event to the enclosing function" do
    events = Compile.trace(@source, "lib/sample.ex")

    assert Enum.all?(
             events,
             &match?({name, arity} when is_atom(name) and is_integer(arity), &1.function)
           )

    assert Enum.map(find_all(events, {Grasp.TracerTest.Sample, :helper, 1}), & &1.function) == [
             {:run, 1},
             {:run, 1}
           ]
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
