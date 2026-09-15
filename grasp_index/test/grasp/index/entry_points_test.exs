defmodule Grasp.Index.EntryPointsTest do
  use ExUnit.Case, async: true, group: :mix_shell

  alias Grasp.Index.EntryPoints

  @empty %{entry_points: [], behaviours: %{}}

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
end
