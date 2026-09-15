defmodule Grasp.Index.BuilderTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)

  setup_all do
    out = Path.join(System.tmp_dir!(), "grasp-sample-#{System.unique_integer([:positive])}.json")
    env = [{"MIX_ENV", "dev"}]

    unless File.dir?(Path.join(@fixture, "deps/sourceror")) do
      {_, 0} = System.cmd("mix", ["deps.get"], cd: @fixture, env: env, stderr_to_stdout: true)
    end

    {output, status} =
      System.cmd("mix", ["grasp.index", "--out", out],
        cd: @fixture,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    {:ok, index} = Grasp.Index.load(out)
    %{index: index, output: output}
  end

  test "reports what it wrote", %{output: output} do
    assert output =~
             ~r/Grasp index written to .*grasp-sample-\d+\.json \(\d+ functions, \d+ calls, \d+ hidden\)/
  end

  test "records project metadata", %{index: index} do
    assert index.project["app"] == "sample_app"
    assert index.project["elixirc_paths"] == ["lib"]
    assert index.project["root"] == @fixture
    assert is_binary(index.generated_at)
  end

  test "indexes definitions with spans, sources and default arities", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert greet["arities"] == [1, 2]
    assert greet["kind"] == "def"
    assert greet["file"] == "lib/sample_app/greeter.ex"
    assert greet["span"] == %{"start_line" => 6, "end_line" => 11}
    assert String.starts_with?(greet["source"], "  @doc \"Greets someone")
    assert greet["change"] == "unchanged"
    assert greet["removed"] == false
  end

  test "resolves aliased, imported, local, captured and nested calls with ranges", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert %{"kind" => "remote", "range" => %{"start" => [9, 12], "end" => [9, 26]}} =
             call(greet, "SampleApp.Formatter.wrap/1")

    assert %{"kind" => "imported", "range" => %{"start" => [10, 19], "end" => [10, 24]}} =
             call(greet, "SampleApp.Formatter.shout/1")

    {:ok, greet_all} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet_all/1")
    assert %{"kind" => "remote"} = call(greet_all, "Enum.map/2")

    assert %{"kind" => "local", "range" => %{"start" => [15, 46], "end" => [15, 51]}} =
             call(greet_all, "SampleApp.Greeter.greet/1")

    assert Grasp.Index.callers(index, "SampleApp.Greeter.greet/2") == [
             "SampleApp.Greeter.Nested.hello/0",
             "SampleApp.Greeter.greet_all/1",
             "SampleApp.Workers.Mailer.perform/1",
             "SampleAppWeb.GreetController.create/2",
             "SampleAppWeb.GreetController.show/2",
             "SampleAppWeb.GreetingComponent.render/1",
             "SampleAppWeb.HelloLive.render/1"
           ]
  end

  test "keeps a context call made inside a template as a hidden call", %{index: index} do
    {:ok, render} = Grasp.Index.fetch_function(index, "SampleAppWeb.HelloLive.render/1")

    assert render["hidden_calls"] == [
             %{"target" => "SampleApp.Greeter.greet/1", "kind" => "remote", "line" => 12}
           ]

    assert "SampleApp.Greeter.greet/2" in Grasp.Index.callees(
             index,
             "SampleAppWeb.HelloLive.render/1"
           )
  end

  test "lists modules including nested ones", %{index: index} do
    names = index |> Grasp.Index.modules() |> Enum.map(& &1["name"])

    assert "SampleApp.Greeter" in names
    assert "SampleApp.Greeter.Nested" in names
    assert "SampleApp.Formatter" in names
  end

  test "records entry points", %{index: index} do
    entries = Grasp.Index.entry_points(index)
    by_kind = Enum.group_by(entries, & &1["kind"])

    assert %{
             "label" => "GET /greet/:name",
             "target" => "SampleAppWeb.GreetController.show/2",
             "meta" => %{
               "verb" => "GET",
               "path" => "/greet/:name",
               "router" => "SampleAppWeb.Router"
             }
           } = find(entries, "SampleAppWeb.GreetController.show/2")

    assert find(entries, "SampleAppWeb.GreetController.create/2")["label"] == "POST /greet"

    assert %{
             "kind" => "live_route",
             "label" => "GET /hello",
             "target" => "SampleAppWeb.HelloLive.mount/3"
           } =
             Enum.find(entries, &(&1["kind"] == "live_route"))

    assert %{"meta" => %{"queue" => "mail", "max_attempts" => 5}} =
             find(entries, "SampleApp.Workers.Mailer.perform/1")

    live_targets = by_kind["live_view"] |> Enum.map(& &1["target"]) |> Enum.sort()

    assert live_targets == [
             "SampleAppWeb.HelloLive.handle_event/3",
             "SampleAppWeb.HelloLive.mount/3",
             "SampleAppWeb.HelloLive.render/1"
           ]

    component_targets = by_kind["live_component"] |> Enum.map(& &1["target"]) |> Enum.sort()

    assert component_targets == [
             "SampleAppWeb.GreetingComponent.handle_event/3",
             "SampleAppWeb.GreetingComponent.render/1"
           ]

    refute Enum.any?(
             by_kind["live_view"],
             &String.starts_with?(&1["target"], "SampleAppWeb.GreetingComponent.")
           )

    genserver_targets = by_kind["genserver"] |> Enum.map(& &1["target"]) |> Enum.sort()
    assert genserver_targets == ["SampleApp.Counter.handle_call/3", "SampleApp.Counter.init/1"]

    assert [%{"target" => "SampleApp.Application.start/2"}] = by_kind["application"]
    assert [%{"target" => "SampleAppWeb.RequestId.call/2"}] = by_kind["plug"]

    refute Enum.any?(
             entries,
             &String.starts_with?(&1["target"], "SampleAppWeb.GreetController.call/")
           )

    refute Enum.any?(entries, &String.starts_with?(&1["target"], "SampleAppWeb.Endpoint."))
    assert entries == Enum.sort_by(entries, &{kind_rank(&1["kind"]), &1["label"], &1["target"]})
  end

  test "records module behaviours", %{index: index} do
    mods = Map.new(Grasp.Index.modules(index), &{&1["name"], &1["behaviours"]})

    assert "Phoenix.LiveComponent" in mods["SampleAppWeb.GreetingComponent"]
    assert "Oban.Worker" in mods["SampleApp.Workers.Mailer"]
    assert "GenServer" in mods["SampleApp.Counter"]
    assert mods["SampleApp.Formatter"] == []
  end

  defp call(record, target), do: Enum.find(record["calls"], &(&1["target"] == target))

  defp find(entries, target), do: Enum.find(entries, &(&1["target"] == target))

  defp kind_rank(kind) do
    Enum.find_index(
      ~w(route live_route oban_worker live_view live_component genserver supervisor application plug),
      &(&1 == kind)
    )
  end
end
