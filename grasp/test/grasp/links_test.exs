defmodule Grasp.LinksTest do
  use ExUnit.Case, async: true

  alias Grasp.Links

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @hello_render "SampleAppWeb.HelloLive.render/1"

  setup_all do
    {:ok, index} = Grasp.Index.load("test/fixtures/index.json")
    %{index: index}
  end

  test "a visible call comes back spelled the way the caller wrote it", %{index: index} do
    assert Links.call_target(index, @show, @greet) == "SampleApp.Greeter.greet/1"
  end

  test "a hidden call links too", %{index: index} do
    assert Links.call_target(index, @hello_render, @greet) == "SampleApp.Greeter.greet/1"
  end

  test "a call the caller does not make has no target", %{index: index} do
    assert Links.call_target(index, @wrap, @show) == nil
    assert Links.call_target(index, "Nope.f/0", @show) == nil
  end

  test "the callee may be named by a default-argument alias", %{index: index} do
    assert Links.call_target(index, @show, "SampleApp.Greeter.greet/1") ==
             "SampleApp.Greeter.greet/1"
  end
end
