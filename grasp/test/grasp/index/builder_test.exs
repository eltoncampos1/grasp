defmodule Grasp.Index.BuilderTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)

  setup_all do
    out = Path.join(System.tmp_dir!(), "grasp-sample-#{System.unique_integer([:positive])}.json")
    env = [{"MIX_ENV", "dev"}]

    unless Enum.all?(locked_deps(), &File.dir?(Path.join([@fixture, "deps", &1]))) do
      {fetched, status} =
        System.cmd("mix", ["deps.get"], cd: @fixture, env: env, stderr_to_stdout: true)

      assert status == 0, fetched
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
    assert index.git["base_ref"] == nil
    assert index.git["base_sha"] == nil
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
             "SampleAppWeb.GreetHTML.show/1",
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

  test "indexes an embedded template as a record of its own", %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")
    file = Path.join(@fixture, "lib/sample_app_web/greet_html/show.html.heex")

    assert show["kind"] == "template"
    assert show["file"] == "lib/sample_app_web/greet_html/show.html.heex"
    assert show["span"] == %{"start_line" => 1, "end_line" => 4}
    assert show["source"] == File.read!(file)

    assert %{"range" => %{"start" => [1, 2], "end" => [1, 8]}} =
             call(show, "SampleAppWeb.GreetHTML.badge/1")

    assert %{"range" => %{"start" => [2, 2], "end" => [2, 39]}} =
             call(show, "SampleAppWeb.GreetingComponent.render/1")

    assert %{"kind" => "remote", "line" => 4} = hidden(show, "SampleApp.Greeter.greet/1")
  end

  test "reaches the template a controller renders and the component a template calls",
       %{index: index} do
    {:ok, controller} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.show/2")

    assert %{"kind" => "template", "range" => %{"start" => [7, 5], "end" => [7, 11]}} =
             call(controller, "SampleAppWeb.GreetHTML.show/1")

    {:ok, live} = Grasp.Index.fetch_function(index, "SampleAppWeb.HelloLive.render/1")

    assert %{"kind" => "remote", "range" => %{"start" => [13, 6], "end" => [13, 43]}} =
             call(live, "SampleAppWeb.GreetingComponent.render/1")

    assert Grasp.Index.callers(index, "SampleAppWeb.GreetingComponent.render/1") == [
             "SampleAppWeb.GreetHTML.show/1",
             "SampleAppWeb.HelloLive.render/1"
           ]
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

    assert labelled(entries, "POST /greet")["target"] == "SampleAppWeb.GreetController.create/2"

    assert %{
             "kind" => "route",
             "target" => "SampleAppWeb.GreetController.create/2",
             "meta" => %{"path" => "/api/echo", "router" => "SampleAppWeb.ApiRouter"}
           } = labelled(entries, "POST /api/echo")

    refute Enum.any?(entries, &(&1["meta"]["path"] == "/echo"))

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

    assert [%{"target" => "SampleApp.Supervisor.init/1"}] = by_kind["supervisor"]
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

  # The fixture keeps its dependencies between runs, so they are fetched only when the lock
  # names one the deps directory does not hold — which is also what a dependency added to
  # Grasp looks like from here.
  defp locked_deps do
    @fixture
    |> Path.join("mix.lock")
    |> File.read!()
    |> then(&Regex.scan(~r/^\s+"([^"]+)":/m, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp call(record, target), do: Enum.find(record["calls"], &(&1["target"] == target))

  defp hidden(record, target),
    do: Enum.find(record["hidden_calls"], &(&1["target"] == target))

  defp find(entries, target), do: Enum.find(entries, &(&1["target"] == target))

  defp labelled(entries, label), do: Enum.find(entries, &(&1["label"] == label))

  defp kind_rank(kind) do
    Enum.find_index(
      ~w(route live_route oban_worker live_view live_component genserver supervisor application plug),
      &(&1 == kind)
    )
  end
end
