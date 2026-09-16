defmodule Grasp.Index.ChangesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.{Changes, Extract, Join}

  @base_a ~S"""
  defmodule A do
    def f, do: :f

    def g(x) do
      x + 1
    end

    def h, do: :h
  end
  """

  @current_a ~S"""
  defmodule A do
    def f, do: :f

    def g(x) do
      x + 2
    end

    def new, do: :new
  end
  """

  @untouched ~S"""
  defmodule U do
    def k, do: :k
  end
  """

  @moved ~S"""
  defmodule A do
    def f, do: :f
  end
  """

  @base_defaults ~S"""
  defmodule A do
    def f(a), do: a

    def g, do: :g
  end
  """

  @current_defaults ~S"""
  defmodule A do
    def f(a, b \\ 1), do: a + b
  end
  """

  test "classifies added, modified and unchanged functions and appends removed ones" do
    classified =
      Changes.classify(records(@current_a, "lib/a.ex"), %{"lib/a.ex" => @base_a}, ["lib"])

    by_id = by_id(classified)

    assert Enum.map(classified, & &1.id) == ["A.f/0", "A.g/1", "A.new/0", "A.h/0"]

    assert by_id["A.f/0"].change == "unchanged"
    assert by_id["A.f/0"].base_source == nil
    assert by_id["A.f/0"].removed == false

    assert by_id["A.g/1"].change == "modified"
    assert by_id["A.g/1"].base_source =~ "x + 1"
    assert by_id["A.g/1"].source =~ "x + 2"
    assert by_id["A.g/1"].removed == false

    assert by_id["A.new/0"].change == "added"
    assert by_id["A.new/0"].base_source == nil
  end

  test "turns a definition the base holds and the index does not into a removed record" do
    classified =
      Changes.classify(records(@current_a, "lib/a.ex"), %{"lib/a.ex" => @base_a}, ["lib"])

    removed = by_id(classified)["A.h/0"]

    assert removed.change == "removed"
    assert removed.removed == true
    assert removed.calls == []
    assert removed.hidden_calls == []
    assert removed.source == removed.base_source
    assert removed.source =~ "def h, do: :h"
    assert removed.file == "lib/a.ex"
    assert removed.span == %{start_line: 8, end_line: 8}
    assert removed.module == "A"
    assert removed.name == :h
    assert removed.arity == 0
    assert removed.arities == [0]
    assert removed.kind == :def
  end

  test "a record in a file the diff did not touch is unchanged" do
    records = records(@current_a, "lib/a.ex") ++ records(@untouched, "lib/u.ex")
    classified = Changes.classify(records, %{"lib/a.ex" => @base_a}, ["lib"])

    assert by_id(classified)["U.k/0"].change == "unchanged"
    assert by_id(classified)["A.new/0"].change == "added"
  end

  test "every function of a file the branch added is added" do
    records = records(@current_a, "lib/a.ex") ++ records(@untouched, "lib/u.ex")
    classified = Changes.classify(records, %{"lib/a.ex" => @base_a, "lib/u.ex" => ""}, ["lib"])

    assert by_id(classified)["U.k/0"].change == "added"
  end

  test "a function moved to another file with its text intact is unchanged" do
    classified = Changes.classify(records(@moved, "lib/b.ex"), %{"lib/a.ex" => @base_a}, ["lib"])
    by_id = by_id(classified)

    assert by_id["A.f/0"].change == "unchanged"
    assert by_id["A.f/0"].file == "lib/b.ex"
    assert by_id["A.g/1"].change == "removed"
    assert by_id["A.h/0"].change == "removed"
  end

  test "a function that gains a default argument is modified under its new id, not removed" do
    classified =
      Changes.classify(
        records(@current_defaults, "lib/a.ex"),
        %{"lib/a.ex" => @base_defaults},
        ["lib"]
      )

    by_id = by_id(classified)

    assert Enum.map(classified, & &1.id) == ["A.f/2", "A.g/0"]

    assert by_id["A.f/2"].change == "modified"
    assert by_id["A.f/2"].base_source =~ "def f(a), do: a"
    assert by_id["A.f/2"].removed == false
    assert by_id["A.f/2"].arities == [1, 2]

    refute Enum.any?(classified, &(&1.id == "A.f/1"))
  end

  test "a definition the current file really dropped is still removed" do
    classified =
      Changes.classify(
        records(@current_defaults, "lib/a.ex"),
        %{"lib/a.ex" => @base_defaults},
        ["lib"]
      )

    removed = by_id(classified)["A.g/0"]

    assert removed.change == "removed"
    assert removed.removed == true
    assert removed.source =~ "def g, do: :g"
  end

  defp records(source, file) do
    {:ok, %{definitions: definitions}} = Extract.extract(source, file)
    Join.join(definitions, [])
  end

  defp by_id(records), do: Map.new(records, &{&1.id, &1})
end
