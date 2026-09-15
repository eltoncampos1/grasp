defmodule GraspWeb.SidebarTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Index
  alias GraspWeb.Sidebar

  @entry_kinds ~w(route live_route oban_worker live_view live_component genserver supervisor
                  application plug)

  test "a kind the project has no entry points for is not rendered as a group" do
    html = [] |> index(without: ["genserver", "plug"]) |> render_sidebar()

    refute html =~ ~s|data-kind="genservers"|
    refute html =~ ~s|data-kind="plugs"|

    assert html =~ ~s|data-kind="routes"|
    assert html =~ ~s|data-kind="modules"|
    assert html =~ ~s|data-kind="otp"|
  end

  test "an index with no entry points at all still offers the module list" do
    html = [] |> index(without: @entry_kinds) |> render_sidebar()

    assert html =~ ~s|data-kind="modules"|
    refute html =~ ~s|class="entry"|
  end

  test "routes sit under the router that declared them, in path order" do
    html = [] |> index() |> render_sidebar(MapSet.new(["routes"]))

    assert html =~ "SampleAppWeb.ApiRouter"
    assert before?(html, "SampleAppWeb.ApiRouter", "SampleAppWeb.Router")
    assert before?(html, "POST /api/echo", "POST /greet")
    assert before?(html, "POST /greet", "GET /greet/:name")
    assert before?(html, "GET /greet/:name", "GET /hello")
  end

  test "an entry of a kind no group collects lands in Other" do
    custom = %{
      "kind" => "custom",
      "label" => "SampleApp.Greeter.greet/2",
      "target" => "SampleApp.Greeter.greet/2",
      "meta" => %{}
    }

    html = [custom] |> index() |> render_sidebar(MapSet.new(["other"]))

    assert html =~ ~s|data-kind="other"|
    assert html =~ "SampleApp.Greeter"
    assert html =~ "greet/2"
  end

  test "the body of a collapsed group is rendered hidden, so its title controls an element" do
    html = [] |> index() |> render_sidebar(MapSet.new())

    assert html =~ ~s|aria-controls="group-routes"|
    assert html =~ ~s|<div id="group-routes" class="group__body" hidden>|
    assert html =~ ~s|<div id="group-modules" class="group__body" hidden>|
  end

  test "a project whose routes read as a list opens them" do
    assert Sidebar.default_expanded(index([])) == MapSet.new(["routes"])
  end

  test "a project with more routes than anyone scans opens nothing" do
    routes =
      for n <- 1..51 do
        %{
          "kind" => "route",
          "label" => "GET /r#{n}",
          "target" => "SampleAppWeb.GreetController.show/2",
          "meta" => %{"verb" => "GET", "path" => "/r#{n}", "router" => "SampleAppWeb.Router"}
        }
      end

    assert routes |> index(without: ["route"]) |> Sidebar.default_expanded() == MapSet.new()
  end

  test "a project with no entry points opens the module list" do
    assert [] |> index(without: @entry_kinds) |> Sidebar.default_expanded() ==
             MapSet.new(["modules"])
  end

  test "no index at all expands nothing" do
    assert Sidebar.default_expanded(nil) == MapSet.new()
  end

  # The fixture is the only index with entry points of every kind, so kinds are removed
  # from its document rather than a second fixture being kept in step with it.
  defp index(extra, opts \\ []) do
    without = Keyword.get(opts, :without, [])

    document =
      "test/fixtures/index.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("entry_points", fn entries ->
        Enum.reject(entries, &(&1["kind"] in without)) ++ extra
      end)

    {:ok, index} = Index.from_document(document)
    index
  end

  defp render_sidebar(index, expanded \\ MapSet.new(["routes"])) do
    render_component(&Sidebar.entry_groups/1,
      index: index,
      expanded: expanded,
      expanded_module: nil
    )
  end

  defp before?(html, first, second) do
    {start, _length} = :binary.match(html, first)
    {later, _length} = :binary.match(html, second)
    start < later
  end
end
