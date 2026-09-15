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

  test "move/3 stores a card's offset and reset_offsets/1 clears it", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "A.f/0")
    [root] = forest.roots
    assert_receive {:session, ^name, ^forest}

    forest = Session.move(name, root, {10, 20})
    assert Forest.card(forest, root).offset == {10, 20}
    assert_receive {:session, ^name, ^forest}

    forest = Session.reset_offsets(name)
    assert Forest.card(forest, root).offset == {0, 0}
    assert_receive {:session, ^name, ^forest}
  end

  test "sessions are isolated by name", %{name: name} do
    other = name <> "-other"
    :ok = Session.ensure(other)
    Session.open_root(name, "A.f/0")
    assert Session.get(other).roots == []
  end

  test "an unknown card id is a no-op that leaves the session running", %{name: name} do
    forest = Session.open_root(name, "A.f/0")

    assert Session.open_child(name, 999, "X.y/0") == forest
    assert Session.get(name) == forest
  end
end
