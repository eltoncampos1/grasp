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

  test "the seed is resolved through a default-arity alias", %{index: index} do
    assert %{paths: [[@greet, @wrap]]} =
             Paths.between(index, "SampleApp.Greeter.greet/1", @wrap, [])
  end

  test "a function is not a path to itself", %{index: index} do
    assert %{paths: []} = Paths.between(index, @wrap, @wrap, [])
  end

  describe "graph shapes" do
    @a "SampleApp.Shapes.a/0"
    @b "SampleApp.Shapes.b/0"
    @c "SampleApp.Shapes.c/0"
    @d "SampleApp.Shapes.d/0"

    test "both same-length routes through a diamond are reported" do
      index = index(%{@a => [@b, @c], @b => [@d], @c => [@d], @d => []})

      assert %{paths: [[@a, @b, @d], [@a, @c, @d]], truncated?: false} =
               Paths.between(index, @a, @d, [])
    end

    test "a cycle terminates with the route that leaves it" do
      index = index(%{@a => [@b], @b => [@a, @c], @c => []})

      assert %{paths: [[@a, @b, @c]], truncated?: false} = Paths.between(index, @a, @c, [])
    end

    test "limit keeps the first paths of the documented order, not of the walk" do
      target = "SampleApp.Target.run/0"
      first = "SampleAppWeb.Alpha.call/0"
      second = "SampleAppWeb.Zeta.call/0"

      index =
        index(
          %{
            target => [],
            "SampleApp.Middle.one/0" => [target],
            "SampleApp.Middle.two/0" => [target],
            first => ["SampleApp.Middle.two/0"],
            second => ["SampleApp.Middle.one/0"]
          },
          [first, second]
        )

      assert %{paths: [[^first, _, ^target], [^second, _, ^target]]} =
               Paths.to_entry_points(index, target, limit: 10)

      assert %{paths: [[^first, _, ^target]]} = Paths.to_entry_points(index, target, limit: 1)
    end

    test "a deeper entry point is reported when the nearer layer leaves room" do
      target = "SampleApp.Target.run/0"
      near = "SampleAppWeb.Near.call/0"
      middle = "SampleApp.Middle.step/0"
      far = "SampleAppWeb.Far.call/0"

      index =
        index(
          %{target => [], near => [target], middle => [target], far => [middle]},
          [near, far]
        )

      assert %{paths: [[^near, ^target], [^far, ^middle, ^target]], truncated?: false} =
               Paths.to_entry_points(index, target, limit: 10)

      assert %{paths: [[^near, ^target]]} = Paths.to_entry_points(index, target, limit: 1)
    end
  end

  defp index(calls, entry_points \\ []) do
    {:ok, index} =
      Grasp.Index.from_document(%{
        "version" => 1,
        "functions" => Enum.map(calls, fn {id, targets} -> record(id, targets) end),
        "entry_points" =>
          Enum.map(entry_points, &%{"kind" => "route", "label" => &1, "target" => &1})
      })

    index
  end

  defp record(id, targets) do
    [qualified, arity] = String.split(id, "/")
    {name, module} = qualified |> String.split(".") |> List.pop_at(-1)

    %{
      "id" => id,
      "module" => Enum.join(module, "."),
      "name" => name,
      "arity" => String.to_integer(arity),
      "calls" => Enum.map(targets, &%{"target" => &1}),
      "hidden_calls" => []
    }
  end
end
