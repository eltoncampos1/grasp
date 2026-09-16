defmodule Grasp.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  describe "search_functions" do
    test "ranks matches and caps them at the limit" do
      {:reply, resp, _} = Tools.SearchFunctions.execute(%{query: "greet", limit: 2}, %Frame{})

      refute resp.isError

      assert %{"results" => [%{"id" => _, "kind" => _, "file" => _, "line" => _} = first, _]} =
               json!(resp)

      assert first["id"] =~ "greet"
    end

    test "reports the definition's start line and change" do
      {:reply, resp, _} = Tools.SearchFunctions.execute(%{query: @wrap, limit: 20}, %Frame{})

      assert %{"results" => [result | _]} = json!(resp)

      assert result == %{
               "id" => @wrap,
               "kind" => "def",
               "file" => "lib/sample_app/formatter.ex",
               "line" => 4,
               "change" => "unchanged"
             }
    end
  end

  describe "get_function" do
    test "returns the record, callers, callees and entry points" do
      {:reply, resp, _} =
        Tools.GetFunction.execute(%{id: "SampleApp.Greeter.greet/1"}, %Frame{})

      body = json!(resp)
      assert body["id"] == @greet
      assert @wrap in body["callees"]
      assert @show in body["callers"]
      refute Map.has_key?(body, "base_source")

      {:reply, resp, _} = Tools.GetFunction.execute(%{id: @show}, %Frame{})

      assert %{"entry_points" => [%{"kind" => "route", "label" => "GET /greet/:name"}]} =
               json!(resp)
    end
  end

  describe "get_callers and get_callees" do
    test "answer under the canonical id" do
      {:reply, resp, _} = Tools.GetCallers.execute(%{id: "SampleApp.Greeter.greet/1"}, %Frame{})
      assert %{"id" => @greet, "callers" => callers} = json!(resp)
      assert @show in callers
      assert @greet_all in callers

      {:reply, resp, _} = Tools.GetCallees.execute(%{id: @greet}, %Frame{})
      assert %{"id" => @greet, "callees" => callees} = json!(resp)
      assert @wrap in callees
    end
  end

  describe "unknown ids" do
    test "are tool errors" do
      {:reply, %Response{isError: true}, _} =
        Tools.GetFunction.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.GetCallers.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.GetCallees.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.FindPaths.execute(%{to: "Nope.f/0", max_depth: 6, limit: 5}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.FindPaths.execute(%{to: @wrap, from: "Nope.f/0", max_depth: 6, limit: 5}, %Frame{})
    end
  end

  describe "find_paths" do
    test "annotates each path's entry point" do
      {:reply, resp, _} =
        Tools.FindPaths.execute(%{to: @wrap, max_depth: 6, limit: 10}, %Frame{})

      assert %{"paths" => paths, "truncated" => false} = json!(resp)

      assert %{
               "ids" => [@show, @greet, @wrap],
               "entry" => %{"kind" => "route", "label" => "GET /greet/:name"}
             } in paths
    end

    test "walks callees when given a from" do
      {:reply, resp, _} =
        Tools.FindPaths.execute(%{to: @wrap, from: @show, max_depth: 6, limit: 5}, %Frame{})

      assert %{"paths" => [%{"ids" => [@show, @greet, @wrap]} | _]} = json!(resp)
    end
  end

  describe "list_entry_points" do
    test "filters by kind and query" do
      {:reply, resp, _} =
        Tools.ListEntryPoints.execute(
          %{kind: "route", query: "greet/:name", limit: 100},
          %Frame{}
        )

      assert %{"total" => 1, "entry_points" => [%{"target" => @show}]} = json!(resp)
    end

    test "matches the target as well as the label, case-insensitively" do
      {:reply, resp, _} =
        Tools.ListEntryPoints.execute(%{query: "hellolive", limit: 100}, %Frame{})

      %{"total" => total, "entry_points" => entry_points} = json!(resp)
      assert total == length(entry_points)
      assert total > 0
      assert Enum.all?(entry_points, &(&1["target"] =~ "HelloLive"))
    end

    test "lists every entry point when unfiltered" do
      {:reply, resp, _} = Tools.ListEntryPoints.execute(%{limit: 100}, %Frame{})
      assert %{"total" => total} = json!(resp)
      assert total > 5
    end
  end

  describe "list_modules and list_sessions" do
    test "list modules matching a query" do
      {:reply, resp, _} = Tools.ListModules.execute(%{query: "greeter", limit: 200}, %Frame{})

      assert %{"total" => 2, "modules" => [%{"name" => "SampleApp.Greeter"} | _]} = json!(resp)
    end

    test "list modules carries file and behaviours" do
      {:reply, resp, _} = Tools.ListModules.execute(%{query: "counter", limit: 200}, %Frame{})

      assert %{
               "modules" => [
                 %{
                   "name" => "SampleApp.Counter",
                   "file" => "lib/sample_app/counter.ex",
                   "behaviours" => ["GenServer"]
                 }
               ]
             } = json!(resp)
    end

    test "list the running sessions" do
      name = "t-#{System.unique_integer([:positive])}"
      :ok = Grasp.Session.ensure(name)

      {:reply, resp, _} = Tools.ListSessions.execute(%{}, %Frame{})
      assert name in json!(resp)["sessions"]
    end
  end

  describe "input schemas" do
    test "are what clients see" do
      assert "query" in Tools.SearchFunctions.input_schema()["required"]
      assert "id" in Tools.GetFunction.input_schema()["required"]
      assert "to" in Tools.FindPaths.input_schema()["required"]
      refute "from" in (Tools.FindPaths.input_schema()["required"] || [])
      refute Tools.ListEntryPoints.input_schema()["required"]
    end
  end
end
