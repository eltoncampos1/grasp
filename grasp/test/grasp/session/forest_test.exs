defmodule Grasp.Session.ForestTest do
  use ExUnit.Case, async: true

  alias Grasp.Session.Forest

  test "open_root/2 appends a focused root" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_root(forest, "B.g/0")

    assert forest.roots == [a, b]
    assert forest.focus == b

    assert %{function_id: "B.g/0", parent_id: nil, children: [], opened_by: nil, collapsed: false} =
             Forest.card(forest, b)
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

    assert forest |> Forest.move_focus(:next) |> Forest.move_focus(:prev) |> Map.fetch!(:focus) ==
             b

    # b is the first sibling, so :prev has nowhere to go and leaves focus where it is
    assert Forest.move_focus(forest, :prev).focus == b
    # c is the last sibling, and d the last root
    assert forest |> Forest.focus(c) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == c
    assert forest |> Forest.focus(d) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == d
    assert Forest.move_focus(forest, :parent).focus == a
    assert forest |> Forest.focus(a) |> Forest.move_focus(:child) |> Map.fetch!(:focus) == b
    assert forest |> Forest.focus(a) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == d

    assert forest
           |> Forest.focus(a)
           |> Forest.toggle_collapse(a)
           |> Forest.move_focus(:child)
           |> Map.fetch!(:focus) == a

    assert Forest.move_focus(%{forest | focus: nil}, :next).focus == a
  end

  test "open_child/3 and open_caller/3 are no-ops on an unknown card id" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")

    assert {^forest, nil} = Forest.open_child(forest, 999, "B.g/0")
    assert {^forest, nil} = Forest.open_caller(forest, 999, "Other.k/0")
    assert forest.roots == [a]
  end
end
