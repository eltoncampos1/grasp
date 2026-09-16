defmodule Grasp.PathsTest do
  use ExUnit.Case, async: true

  alias Grasp.Paths

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @create "SampleAppWeb.GreetController.create/2"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @hello_render "SampleAppWeb.HelloLive.render/1"
  @component_render "SampleAppWeb.GreetingComponent.render/1"

  setup_all do
    {:ok, index} = Grasp.Index.load("test/fixtures/index.json")
    %{index: index}
  end

  test "between/4 finds the chain through a default-arity alias", %{index: index} do
    assert %{paths: [[@show, @greet, @wrap]], truncated?: false} =
             Paths.between(index, @show, @wrap, [])
  end

  test "between/4 with no route is empty", %{index: index} do
    assert %{paths: [], truncated?: false} = Paths.between(index, @wrap, @show, [])
  end

  test "to_entry_points/3 walks callers back to every entry point, shortest first", %{
    index: index
  } do
    %{paths: paths, truncated?: false} = Paths.to_entry_points(index, @wrap, limit: 10)

    assert paths == [
             [@perform, @greet, @wrap],
             [@create, @greet, @wrap],
             [@show, @greet, @wrap],
             [@component_render, @greet, @wrap],
             [@hello_render, @greet, @wrap]
           ]
  end

  test "limit and max_depth cut the result", %{index: index} do
    assert %{paths: [_, _]} = Paths.to_entry_points(index, @wrap, limit: 2)
    assert %{paths: []} = Paths.to_entry_points(index, @wrap, max_depth: 1)
  end

  test "an exhausted budget is reported", %{index: index} do
    assert %{truncated?: true} = Paths.to_entry_points(index, @wrap, budget: 1)
  end

  test "an unknown function has no paths", %{index: index} do
    assert %{paths: []} = Paths.between(index, "Nope.f/0", @wrap, [])
  end
end
