defmodule Grasp.Session.ForestTest do
  use ExUnit.Case, async: true

  alias Grasp.Session.Forest

  test "open_root/2 finds the existing card instead of adding a second" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_root(forest, "B.g/0")
    {forest, a_again} = Forest.open_root(forest, "A.f/1")

    assert a_again == a
    assert map_size(forest.cards) == 2
    assert forest.focus == a
    assert Forest.find(forest, "B.g/0") == b
    assert Forest.find(forest, "Z.z/0") == nil

    assert %{id: ^b, function_id: "B.g/0", collapsed: false, offset: {0, 0}, highlight: nil} =
             Forest.card(forest, b)
  end

  test "open_child/4 links parent to child with a coloured edge and reuses the child card" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, a, "C.h/2")

    assert forest.edges == [
             %{from: a, to: b, target: "B.g/0", color: 0},
             %{from: a, to: c, target: "C.h/2", color: 1}
           ]

    assert forest.focus == c

    {forest, b_again} = Forest.open_child(forest, a, "B.g/0")

    assert b_again == b
    assert length(forest.edges) == 2
    assert forest.focus == b
    assert Forest.callees(forest, a) == [b, c]
  end

  test "open_child/4 records the call target the click named" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/2", "B.g/1")

    assert [%{from: ^a, to: ^b, target: "B.g/1"}] = forest.edges
  end

  test "open_child/4 and open_caller/4 are no-ops on an unknown card id" do
    {forest, _a} = Forest.open_root(Forest.new(), "A.f/1")

    assert {^forest, nil} = Forest.open_child(forest, 999, "B.g/0")
    assert {^forest, nil} = Forest.open_caller(forest, 999, "C.h/2")
  end

  test "edge colours cycle through the palette" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")

    forest =
      Enum.reduce(1..9, forest, fn n, forest ->
        {forest, _id} = Forest.open_child(forest, a, "C#{n}.f/0")
        forest
      end)

    assert Enum.map(forest.edges, & &1.color) == [0, 1, 2, 3, 4, 5, 6, 7, 0]
  end

  test "open_caller/4 adds a caller card to the left with an edge into the card" do
    {forest, x} = Forest.open_root(Forest.new(), "X.f/1")
    {forest, c} = Forest.open_caller(forest, x, "C.h/0", "X.f/1")

    assert forest.edges == [%{from: c, to: x, target: "X.f/1", color: 0}]
    assert forest.focus == c
    assert Forest.layout(forest) == [[c], [x]]

    {forest, d} = Forest.open_caller(forest, x, "D.i/0")

    assert Forest.layout(forest) == [[c, d], [x]]
    assert Forest.callers(forest, x) == [c, d]
    assert map_size(forest.cards) == 3
    assert Enum.at(forest.edges, 1).target == "X.f/1"
  end

  test "a function opened under two parents is one card with two edges" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, d} = Forest.open_root(forest, "D.i/0")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, b_again} = Forest.open_child(forest, d, "B.g/0")

    assert b_again == b
    assert Forest.find(forest, "B.g/0") == b
    assert Forest.callers(forest, b) == [a, d]
    assert length(forest.edges) == 2
    assert Forest.layout(forest) == [[a, d], [b]]
  end

  test "close/2 removes one card and its edges, the chain stays" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")

    forest = Forest.close(forest, b)

    assert forest.cards |> Map.keys() |> Enum.sort() == [a, c]
    assert forest.edges == []
    assert Forest.layout(forest) == [[a, c]]
    assert forest.focus == a
  end

  test "close/2 falls back to a callee, then to nothing, and ignores unknown ids" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")

    assert Forest.close(forest, a).focus == b
    assert forest |> Forest.close(a) |> Forest.close(b) |> Map.fetch!(:focus) == nil
    assert Forest.close(forest, 999) == forest
  end

  test "close_chain/2 removes what only the card reached" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")
    {forest, d} = Forest.open_root(forest, "D.i/0")
    {shared, ^c} = Forest.open_child(forest, d, "C.h/2")

    shared = Forest.close_chain(shared, b)

    assert shared.cards |> Map.keys() |> Enum.sort() == [a, c, d]
    assert Forest.callers(shared, c) == [d]

    alone = Forest.close_chain(forest, b)

    assert alone.cards |> Map.keys() |> Enum.sort() == [a, d]
    assert alone.edges == []
    assert alone.focus == a
  end

  test "close_chain/2 takes a cycle that hangs off the closed card with it" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")
    {forest, d} = Forest.open_child(forest, c, "D.i/0")
    {forest, ^c} = Forest.open_child(forest, d, "C.h/2")

    forest = Forest.close_chain(forest, b)

    assert Map.keys(forest.cards) == [a]
  end

  test "close_chain/2 keeps a card the closed one calls back into" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, ^a} = Forest.open_child(forest, b, "A.f/1")

    forest = Forest.close_chain(forest, b)

    assert Map.keys(forest.cards) == [a]
    assert forest.edges == []
  end

  test "collapse hides what is reachable only through the card" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")
    {forest, d} = Forest.open_root(forest, "D.i/0")
    {shared, ^c} = Forest.open_child(forest, d, "C.h/2")

    shared = Forest.toggle_collapse(shared, b)

    assert Forest.hidden(shared) == MapSet.new()
    assert Forest.hidden_count(shared, b) == 0

    alone = Forest.toggle_collapse(forest, b)

    assert Forest.hidden(alone) == MapSet.new([c])
    assert Forest.hidden_count(alone, b) == 1
    assert Forest.hidden_count(alone, a) == 0
    assert Forest.card(alone, b).collapsed
    assert Forest.layout(alone) == [[a, d], [b]]
    assert Forest.depth(alone, c) == 0
    assert Forest.depth(alone, b) == 1
    assert Forest.edges(alone) == [%{from: a, to: b, target: "B.g/0", color: 0}]
    assert Forest.toggle_collapse(alone, b) |> Forest.hidden() == MapSet.new()
  end

  test "a collapse hides a card on both ends of its edges" do
    %{forest: forest, hidden: hidden, callee: callee} = collapsed_detour()

    assert Forest.hidden(forest) == MapSet.new([hidden])
    assert Forest.callers(forest, callee) |> Enum.member?(hidden)
    assert Enum.all?(Forest.edges(forest), &(&1.from != hidden and &1.to != hidden))
  end

  test "move_focus/2 skips a caller a collapse has hidden" do
    %{forest: forest, source: source, callee: callee} = collapsed_detour()

    assert forest |> Forest.focus(callee) |> Forest.move_focus(:parent) |> Map.fetch!(:focus) ==
             source
  end

  test "hidden_count/2 does not count what a collapse further down already hides" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")
    {forest, d} = Forest.open_child(forest, c, "D.i/0")

    forest = forest |> Forest.toggle_collapse(b) |> Forest.toggle_collapse(c)

    assert Forest.hidden(forest) == MapSet.new([c, d])
    # B hides C, and D is already C's to hide; C, hidden itself, hides nothing on screen
    assert Forest.hidden_count(forest, b) == 1
    assert Forest.hidden_count(forest, c) == 0
    assert forest |> Forest.toggle_collapse(c) |> Forest.hidden_count(b) == 2
  end

  test "columns_of/1 reads every visible card's column" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, b, "C.h/2")

    assert Forest.columns_of(forest) == %{a => 0, b => 1, c => 2}
    assert Forest.depth(forest, c) == 2

    collapsed = Forest.toggle_collapse(forest, b)

    assert Forest.columns_of(collapsed) == %{a => 0, b => 1}
  end

  test "layout/1 ignores back-edges" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, ^a} = Forest.open_child(forest, b, "A.f/1")

    assert Forest.layout(forest) == [[a], [b]]
    assert Forest.layout(Forest.new()) == []
  end

  test "layout/1 orders a column by where its callers sit" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, d} = Forest.open_root(forest, "D.i/0")
    {forest, c} = Forest.open_child(forest, a, "C.h/2")
    {forest, b} = Forest.open_child(forest, d, "B.g/0")

    assert Forest.layout(forest) == [[a, d], [c, b]]

    {crossed, a} = Forest.open_root(Forest.new(), "A.f/1")
    {crossed, d} = Forest.open_root(crossed, "D.i/0")
    {crossed, c} = Forest.open_child(crossed, d, "C.h/2")
    {crossed, b} = Forest.open_child(crossed, a, "B.g/0")

    assert Forest.layout(crossed) == [[a, d], [b, c]]
  end

  test "move_focus/2 walks callers, callees and the column" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    {forest, c} = Forest.open_child(forest, a, "C.h/2")

    forest = Forest.focus(forest, b)

    assert Forest.move_focus(forest, :parent).focus == a
    assert forest |> Forest.focus(a) |> Forest.move_focus(:child) |> Map.fetch!(:focus) == b
    assert Forest.move_focus(forest, :next).focus == c
    assert forest |> Forest.focus(c) |> Forest.move_focus(:prev) |> Map.fetch!(:focus) == b

    # the ends of a column and a card with no caller leave focus where it is
    assert forest |> Forest.focus(c) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == c
    assert Forest.move_focus(forest, :prev).focus == b
    assert forest |> Forest.focus(a) |> Forest.move_focus(:parent) |> Map.fetch!(:focus) == a

    assert Forest.move_focus(%{forest | focus: nil}, :next).focus == a
    assert Forest.move_focus(Forest.new(), :next) == Forest.new()
  end

  test "move/3 sets a card's offset and reset_offsets/1 clears every offset" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")

    assert Forest.card(forest, a).offset == {0, 0}
    forest = Forest.move(forest, b, {40, -12})
    assert Forest.card(forest, b).offset == {40, -12}
    assert Forest.move(forest, 999, {1, 1}) == forest

    forest = Forest.reset_offsets(forest)
    assert Forest.card(forest, b).offset == {0, 0}
  end

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
    test "builds one card per function, linking entries by key" do
      spec = [
        %{key: "a", function_id: "A.f/1", parent_key: nil, opened_by: nil, highlight: nil},
        %{
          key: "b",
          function_id: "B.g/0",
          parent_key: "a",
          opened_by: "B.g/1",
          highlight: %{"lines" => [1, 2]}
        },
        %{key: "c", function_id: "B.g/0", parent_key: nil, opened_by: nil, highlight: nil}
      ]

      assert {:ok, forest} = Forest.replace(spec)
      assert map_size(forest.cards) == 2
      assert forest.edges == [%{from: 1, to: 2, target: "B.g/1", color: 0}]
      assert forest.focus == 1
      assert Forest.card(forest, 2).highlight == %{"lines" => [1, 2]}
    end

    test "an unknown parent key is an error" do
      spec = [
        %{key: "b", function_id: "B.g/0", parent_key: "zzz", opened_by: nil, highlight: nil}
      ]

      assert Forest.replace(spec) == {:error, {:unknown_parent, "zzz"}}
    end

    test "a repeated key points at its last entry" do
      spec = [
        %{key: "a", function_id: "A.f/1", parent_key: nil, opened_by: nil, highlight: nil},
        %{key: "a", function_id: "C.h/0", parent_key: nil, opened_by: nil, highlight: nil},
        %{key: "b", function_id: "B.g/0", parent_key: "a", opened_by: nil, highlight: nil}
      ]

      assert {:ok, forest} = Forest.replace(spec)
      assert Forest.callers(forest, 3) == [2]
    end

    test "an empty spec is an empty forest" do
      assert {:ok, %Forest{cards: %{}, edges: [], focus: nil}} = Forest.replace([])
    end
  end

  test "a card starts on :auto, which reads as the diff when there is one" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")

    assert Forest.card(forest, a).view == :auto
    assert Forest.effective_view(:auto, true) == :diff
    assert Forest.effective_view(:auto, false) == :source
    assert Forest.effective_view(:source, true) == :source

    forest = Forest.toggle_view(forest, a)
    assert Forest.card(forest, a).view == :source

    forest = Forest.toggle_view(forest, a)
    assert Forest.card(forest, a).view == :diff

    forest = Forest.toggle_view(forest, a)
    assert Forest.card(forest, a).view == :source
  end

  test "set_view/3 takes one of the two views and ignores an unknown card" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")

    assert Forest.set_view(forest, a, :diff) |> Forest.card(a) |> Map.fetch!(:view) == :diff
    assert Forest.set_view(forest, a, :source) |> Forest.card(a) |> Map.fetch!(:view) == :source
    assert Forest.set_view(forest, 999, :diff) == forest
    assert Forest.toggle_view(forest, 999) == forest

    # Through apply/3, so the type checker does not read the deliberate bad call as a bug.
    assert_raise FunctionClauseError, fn -> apply(Forest, :set_view, [forest, a, :unified]) end
  end

  test "to_map/1 is the JSON shape with cards sorted by id" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")
    forest = Forest.set_highlight(forest, b, %{"call" => "C.h/0"})
    forest = Forest.set_view(forest, b, :diff)

    assert Forest.to_map(forest) == %{
             "focus" => b,
             "cards" => [
               %{
                 "id" => a,
                 "function_id" => "A.f/1",
                 "collapsed" => false,
                 "view" => "auto",
                 "highlight" => nil,
                 "group" => nil,
                 "callers" => [],
                 "callees" => [b]
               },
               %{
                 "id" => b,
                 "function_id" => "B.g/0",
                 "collapsed" => false,
                 "view" => "diff",
                 "highlight" => %{"call" => "C.h/0"},
                 "group" => nil,
                 "callers" => [a],
                 "callees" => []
               }
             ],
             "edges" => [%{"from" => a, "to" => b, "target" => "B.g/0", "color" => 0}],
             "columns" => [[a], [b]],
             "groups" => [],
             "sections" => [%{"group" => nil, "columns" => [[a], [b]]}]
           }
  end

  describe "groups" do
    test "group_cards/3 creates a group, reuses it by title and moves a card between groups" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, c} = Forest.open_child(forest, a, "C.h/2")

      {forest, flow} = Forest.group_cards(forest, "Flow", [a])
      {forest, same} = Forest.group_cards(forest, "Flow", [b])

      assert same == flow
      assert Forest.group_of(forest, a) == %{id: flow, title: "Flow"}
      assert Forest.group_of(forest, b) == %{id: flow, title: "Flow"}
      assert Forest.group_of(forest, c) == nil
      assert Forest.group_of(forest, 999) == nil
      assert Forest.card(forest, a).group == flow
      assert Forest.card(forest, c).group == nil

      {forest, edges} = Forest.group_cards(forest, "Edges", [b])

      assert edges != flow
      assert Forest.group_of(forest, b) == %{id: edges, title: "Edges"}
      assert forest.groups |> Map.keys() |> Enum.sort() == Enum.sort([flow, edges])
    end

    test "group_cards/3 ignores unknown ids and deletes a group left empty" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, flow} = Forest.group_cards(forest, "Flow", [a, 999])

      assert Map.keys(forest.groups) == [flow]
      assert map_size(forest.cards) == 1

      {forest, edges} = Forest.group_cards(forest, "Edges", [a])

      assert Map.keys(forest.groups) == [edges]
      assert Forest.group_of(forest, a).title == "Edges"
    end

    test "ungroup_cards/2 and dissolve_group/2 take cards out and delete the empty group" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, flow} = Forest.group_cards(forest, "Flow", [a, b])

      ungrouped = Forest.ungroup_cards(forest, [a, 999])

      assert Forest.group_of(ungrouped, a) == nil
      assert Forest.group_of(ungrouped, b).id == flow
      assert Map.keys(ungrouped.groups) == [flow]
      assert ungrouped |> Forest.ungroup_cards([b]) |> Map.fetch!(:groups) == %{}

      dissolved = Forest.dissolve_group(forest, flow)

      assert dissolved.groups == %{}
      assert Forest.group_of(dissolved, a) == nil
      assert Forest.group_of(dissolved, b) == nil
      assert Forest.dissolve_group(forest, 999) == forest
    end

    test "rename_group/3 retitles a group, leaving unknown ids and blank titles alone" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, flow} = Forest.group_cards(forest, "Flow", [a])

      renamed = Forest.rename_group(forest, flow, "Deposits")

      assert Forest.group(renamed, flow) == %{id: flow, title: "Deposits"}
      assert Forest.group_of(renamed, a) == %{id: flow, title: "Deposits"}
      assert Forest.group(renamed, 999) == nil

      assert Forest.rename_group(forest, 999, "Deposits") == forest
      assert Forest.rename_group(forest, flow, "   ") == forest
      assert Forest.rename_group(forest, flow, "") == forest
    end

    test "add_to_group/3 joins an existing group and deletes the one it empties" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, c} = Forest.open_child(forest, a, "C.h/2")
      {forest, flow} = Forest.group_cards(forest, "Flow", [a])
      {forest, edges} = Forest.group_cards(forest, "Edges", [b])

      joined = Forest.add_to_group(forest, flow, [b, c, 999])

      assert Forest.group_of(joined, b).id == flow
      assert Forest.group_of(joined, c).id == flow
      assert Map.keys(joined.groups) == [flow]
      assert map_size(joined.cards) == 3

      assert Forest.add_to_group(forest, 999, [a]) == forest
      assert Forest.add_to_group(forest, edges, []) == forest
    end

    test "sections/1 lays every group out on its own, ungrouped cards last" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, c} = Forest.open_root(forest, "C.h/2")
      {forest, d} = Forest.open_child(forest, c, "D.i/0")
      {forest, flow} = Forest.group_cards(forest, "Flow", [c, d])

      assert flow == 1

      assert Forest.sections(forest) == [
               %{group: %{id: flow, title: "Flow"}, columns: [[c], [d]]},
               %{group: nil, columns: [[a], [b]]}
             ]

      assert Forest.layout(forest) == [[c], [d], [a], [b]]
      assert Forest.columns_of(forest) == %{c => 0, d => 1, a => 0, b => 1}
      assert Forest.depth(forest, b) == 1
      assert Forest.sections(Forest.new()) == []
    end

    test "sections/1 makes a member its own source when every caller sits outside" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, _flow} = Forest.group_cards(forest, "Flow", [b])

      assert [%{group: %{title: "Flow"}, columns: [[^b]]}, %{group: nil, columns: [[^a]]}] =
               Forest.sections(forest)

      assert Forest.depth(forest, b) == 0
    end

    test "move_focus/2 stays inside the focused card's section" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_root(forest, "B.g/0")
      {forest, c} = Forest.open_root(forest, "C.h/2")
      {forest, _flow} = Forest.group_cards(forest, "Flow", [c])

      assert Forest.layout(forest) == [[c], [a, b]]
      assert forest |> Forest.focus(c) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == c
      assert forest |> Forest.focus(a) |> Forest.move_focus(:next) |> Map.fetch!(:focus) == b
    end

    test "closing the last member of a group deletes the group" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, c} = Forest.open_child(forest, b, "C.h/2")
      {forest, flow} = Forest.group_cards(forest, "Flow", [b, c])

      kept = Forest.close(forest, b)

      assert Map.keys(kept.groups) == [flow]
      assert Forest.group_of(kept, c).id == flow
      assert kept |> Forest.close(c) |> Map.fetch!(:groups) == %{}
      assert forest |> Forest.close_chain(b) |> Map.fetch!(:groups) == %{}
      assert Forest.group_of(Forest.close(forest, b), a) == nil
    end

    test "replace/1 groups cards by title, in first-appearance order" do
      spec = [
        spec("a", "A.f/1", nil, nil),
        spec("b", "B.g/0", "a", "Writes"),
        spec("c", "C.h/2", "a", "Reads"),
        spec("d", "D.i/0", "c", "Writes")
      ]

      assert {:ok, forest} = Forest.replace(spec)
      assert forest.groups == %{1 => %{id: 1, title: "Writes"}, 2 => %{id: 2, title: "Reads"}}
      assert Forest.group_of(forest, 1) == nil
      assert Forest.group_of(forest, 2).title == "Writes"
      assert Forest.group_of(forest, 4).title == "Writes"

      assert Forest.sections(forest) == [
               %{group: %{id: 1, title: "Writes"}, columns: [[2, 4]]},
               %{group: %{id: 2, title: "Reads"}, columns: [[3]]},
               %{group: nil, columns: [[1]]}
             ]
    end

    test "to_map/1 carries each card's group, the groups and the sections" do
      {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
      {forest, b} = Forest.open_child(forest, a, "B.g/0")
      {forest, flow} = Forest.group_cards(forest, "Flow", [b])

      map = Forest.to_map(forest)

      assert Enum.map(map["cards"], & &1["group"]) == [nil, flow]
      assert map["groups"] == [%{"id" => flow, "title" => "Flow", "cards" => [b]}]

      assert map["sections"] == [
               %{"group" => flow, "columns" => [[b]]},
               %{"group" => nil, "columns" => [[a]]}
             ]

      assert map["columns"] == [[b], [a]]
    end
  end

  # A `replace/1` entry with nothing to say about call targets or highlights.
  defp spec(key, function_id, parent_key, group) do
    %{
      key: key,
      function_id: function_id,
      parent_key: parent_key,
      opened_by: nil,
      highlight: nil,
      group: group
    }
  end

  # S calls X and C; X calls H, which also calls C. Collapsing X hides H alone: C keeps its
  # other way in, so an edge from a hidden card and a hidden caller both stay in the data.
  defp collapsed_detour do
    {forest, source} = Forest.open_root(Forest.new(), "S.f/0")
    {forest, detour} = Forest.open_child(forest, source, "X.f/0")
    {forest, hidden} = Forest.open_child(forest, detour, "H.f/0")
    {forest, callee} = Forest.open_child(forest, hidden, "C.f/0")
    {forest, ^callee} = Forest.open_child(forest, source, "C.f/0")

    %{
      forest: Forest.toggle_collapse(forest, detour),
      source: source,
      hidden: hidden,
      callee: callee
    }
  end
end
