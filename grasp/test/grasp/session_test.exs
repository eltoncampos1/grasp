defmodule Grasp.SessionTest do
  # The persistence tests replace the application-wide sessions directory, so this module
  # runs alone.
  use ExUnit.Case, async: false

  alias Grasp.Session
  alias Grasp.Session.Disk
  alias Grasp.Session.Forest

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    :ok = Session.ensure(name)
    %{name: name}
  end

  test "ensure/1 is idempotent and get/1 starts empty", %{name: name} do
    assert :ok = Session.ensure(name)
    assert %Forest{cards: %{}, edges: [], focus: nil} = Session.get(name)
  end

  test "operations mutate the forest and broadcast it", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    root = forest.focus
    assert_receive {:session, ^name, ^forest}

    forest = Session.open_child(name, root, "SampleApp.Formatter.wrap/1")
    [child] = Forest.callees(forest, root)
    assert Forest.card(forest, child).function_id == "SampleApp.Formatter.wrap/1"
    assert_receive {:session, ^name, ^forest}

    forest = Session.toggle_collapse(name, root)
    assert Forest.card(forest, root).collapsed

    forest = Session.move_focus(name, :parent)
    assert forest.focus == root

    forest = Session.close(name, root)
    assert Forest.card(forest, root) == nil
    assert Session.get(name) == forest
  end

  test "open_caller/4 stacks a caller to the left of the card", %{name: name} do
    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    card_id = forest.focus

    forest =
      Session.open_caller(
        name,
        card_id,
        "SampleAppWeb.GreetController.show/2",
        "SampleApp.Greeter.greet/1"
      )

    caller = forest.focus
    assert Forest.callers(forest, card_id) == [caller]
    assert [%{target: "SampleApp.Greeter.greet/1"}] = forest.edges
    assert Forest.layout(forest) == [[caller], [card_id]]
  end

  test "close_chain/2 drops what only the closed card reached", %{name: name} do
    forest = Session.open_root(name, "A.f/1")
    a = forest.focus
    forest = Session.open_child(name, a, "B.g/0")
    b = forest.focus
    Session.open_child(name, b, "C.h/2")

    forest = Session.close_chain(name, b)

    assert Map.keys(forest.cards) == [a]
    assert Session.get(name) == forest
  end

  test "move/3 stores a card's offset and reset_offsets/1 clears it", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "A.f/0")
    root = forest.focus
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
    assert Session.get(other).cards == %{}
  end

  test "an unknown card id is a no-op that leaves the session running", %{name: name} do
    forest = Session.open_root(name, "A.f/0")

    assert Session.open_child(name, 999, "X.y/0") == forest
    assert Session.get(name) == forest
  end

  test "set_cards replaces the forest and broadcasts once; an error leaves it untouched", %{
    name: name
  } do
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
    %{focus: id} = Session.open_root(name, "A.f/1")
    forest = Session.set_highlight(name, id, %{"lines" => [2, 3]})
    assert Forest.card(forest, id).highlight == %{"lines" => [2, 3]}
    assert_receive {:session, ^name, ^forest}
  end

  test "set_view and toggle_view broadcast the card's view", %{name: name} do
    Session.subscribe(name)
    %{focus: id} = Session.open_root(name, "A.f/1")

    forest = Session.set_view(name, id, :diff)
    assert Forest.card(forest, id).view == :diff
    assert_receive {:session, ^name, ^forest}

    forest = Session.toggle_view(name, id)
    assert Forest.card(forest, id).view == :source
    assert_receive {:session, ^name, ^forest}
    assert Session.get(name) == forest
  end

  test "group_cards, ungroup_cards and dissolve_group mirror the forest and broadcast", %{
    name: name
  } do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    root = forest.focus
    assert_receive {:session, ^name, ^forest}

    forest = Session.group_cards(name, "Greeting", [root])
    assert %{title: "Greeting"} = Forest.group_of(forest, root)
    assert Forest.sections(forest) == [%{group: Forest.group_of(forest, root), columns: [[root]]}]
    assert_receive {:session, ^name, ^forest}

    forest = Session.ungroup_cards(name, [root])
    assert Forest.group_of(forest, root) == nil
    assert forest.groups == %{}
    assert_receive {:session, ^name, ^forest}

    forest = Session.group_cards(name, "Greeting", [root])
    group_id = Forest.group_of(forest, root).id
    assert_receive {:session, ^name, ^forest}

    forest = Session.dissolve_group(name, group_id)
    assert forest.groups == %{}
    assert Forest.group_of(forest, root) == nil
    assert_receive {:session, ^name, ^forest}
    assert Session.get(name) == forest
  end

  test "new_group makes an untitled group of its own and broadcasts", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    root = forest.focus
    assert_receive {:session, ^name, ^forest}

    forest = Session.new_group(name, nil, [root])
    group = Forest.group_of(forest, root)

    assert group.title == nil
    assert_receive {:session, ^name, ^forest}

    forest = Session.new_group(name, nil, [root])

    assert Forest.group_of(forest, root).id != group.id
    assert Session.get(name) == forest
  end

  test "rename_group and add_to_group mirror the forest and broadcast", %{name: name} do
    :ok = Session.subscribe(name)

    forest = Session.open_root(name, "SampleApp.Greeter.greet/2")
    root = forest.focus
    forest = Session.open_child(name, root, "SampleApp.Formatter.wrap/1")
    [child] = Forest.callees(forest, root)

    forest = Session.group_cards(name, "Greeting", [root])
    greeting = Forest.group_of(forest, root).id

    forest = Session.rename_group(name, greeting, "Request")

    assert Forest.group_of(forest, root) == %{id: greeting, title: "Request"}
    assert_receive {:session, ^name, ^forest}

    forest = Session.add_to_group(name, greeting, [child])

    assert Forest.group_of(forest, child).id == greeting
    assert_receive {:session, ^name, ^forest}
    assert Session.get(name) == forest
  end

  test "list/0 names the running sessions", %{name: name} do
    assert name in Session.list()
  end

  describe "persistence" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      previous = Application.get_env(:grasp, :sessions_dir)
      Application.put_env(:grasp, :sessions_dir, tmp_dir)
      on_exit(fn -> Application.put_env(:grasp, :sessions_dir, previous) end)

      :ok
    end

    test "a session that stopped comes back with the cards it had", %{tmp_dir: tmp_dir} do
      name = "disk-#{System.unique_integer([:positive])}"
      :ok = Session.ensure(name)
      card = Session.open_root(name, "SampleApp.Greeter.greet/2").focus

      assert wait_for_file(Path.join(tmp_dir, name <> ".json"))

      [{pid, _registered}] = Registry.lookup(Grasp.SessionRegistry, name)
      :ok = GenServer.stop(pid)
      :ok = Session.ensure(name)

      reloaded = Session.get(name)

      assert Forest.card(reloaded, card).function_id == "SampleApp.Greeter.greet/2"
      assert reloaded.focus == card
    end

    test "list/0 names a saved session no process is running" do
      name = "saved-#{System.unique_integer([:positive])}"
      {forest, _card} = Forest.open_root(Forest.new(), "SampleApp.Greeter.greet/2")
      :ok = Disk.write(name, forest)

      assert Registry.lookup(Grasp.SessionRegistry, name) == []
      assert name in Session.list()
    end

    test "delete/1 tells the subscribers, stops the session and removes its file", %{
      tmp_dir: tmp_dir
    } do
      name = "gone-#{System.unique_integer([:positive])}"
      :ok = Session.ensure(name)
      :ok = Session.subscribe(name)
      Session.open_root(name, "SampleApp.Greeter.greet/2")
      path = Path.join(tmp_dir, name <> ".json")

      assert wait_for_file(path)
      assert Session.delete(name) == :ok
      assert_receive {:session_deleted, ^name}

      refute File.exists?(path)
      assert Registry.lookup(Grasp.SessionRegistry, name) == []
      refute name in Session.list()
    end

    test "two mutations in one burst are written once", %{tmp_dir: tmp_dir} do
      name = "burst-#{System.unique_integer([:positive])}"
      :ok = Session.ensure(name)
      path = Path.join(tmp_dir, name <> ".json")

      card = Session.open_root(name, "SampleApp.Greeter.greet/2").focus
      Session.move(name, card, {10, 10})

      refute File.exists?(path)
      assert wait_for_file(path)

      assert {:ok, written} = Disk.read(name, nil)
      assert Forest.card(written, card).offset == {10, 10}
    end
  end

  # A write is debounced, so the file appears a moment after the mutation that asks for it.
  defp wait_for_file(path, attempts \\ 100) do
    cond do
      File.exists?(path) ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_for_file(path, attempts - 1)
    end
  end
end
