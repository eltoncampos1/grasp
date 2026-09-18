defmodule Grasp.Index.EntryPointsTest do
  use ExUnit.Case, async: true, group: :mix_shell

  alias Grasp.Index.EntryPoints

  @empty %{entry_points: [], behaviours: %{}, skipped: []}

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "reports nothing when the application has no modules" do
    assert EntryPoints.detect(:no_such_app, MapSet.new()) == @empty
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "no application modules found for :no_such_app"
  end

  test "reports nothing for an umbrella root, which has no application of its own" do
    assert EntryPoints.detect(nil, MapSet.new()) == @empty
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "no application modules found for nil"
  end

  test "a live route points at the first of mount, handle_params and render the index holds" do
    indexed = MapSet.new(["My.View.handle_params/3", "My.View.render/1"])
    assert EntryPoints.live_route_target(My.View, indexed) == "My.View.handle_params/3"
  end

  test "a live route falls back to the view's first indexed function" do
    indexed = MapSet.new(["My.View.handle_event/3", "My.View.terminate/2", "Other.View.render/1"])
    assert EntryPoints.live_route_target(My.View, indexed) == "My.View.handle_event/3"
  end

  test "a live route whose view has no indexed function has no target" do
    assert EntryPoints.live_route_target(My.View, MapSet.new(["My.View.Nested.run/0"])) == nil
  end
end
