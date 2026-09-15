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
             "SampleAppWeb.GreetController.show/2"
           ]
  end

  test "lists modules including nested ones, with an empty behaviours list", %{index: index} do
    modules = Grasp.Index.modules(index)
    names = Enum.map(modules, & &1["name"])

    assert "SampleApp.Greeter" in names
    assert "SampleApp.Greeter.Nested" in names
    assert "SampleApp.Formatter" in names
    assert Enum.all?(modules, &(&1["behaviours"] == []))
  end

  test "carries empty entry points until milestone 3", %{index: index} do
    assert Grasp.Index.entry_points(index) == []
  end

  defp call(record, target), do: Enum.find(record["calls"], &(&1["target"] == target))
end
