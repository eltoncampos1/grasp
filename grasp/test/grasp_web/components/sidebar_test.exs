defmodule GraspWeb.SidebarTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Index
  alias GraspWeb.Sidebar

  @greet "SampleApp.Greeter.greet/2"

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
    html = [] |> index(without: @entry_kinds, unchanged: true) |> render_sidebar()

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
    assert [] |> index(unchanged: true) |> Sidebar.default_expanded() == MapSet.new(["routes"])
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

    assert routes |> index(without: ["route"], unchanged: true) |> Sidebar.default_expanded() ==
             MapSet.new()
  end

  test "a project with no entry points opens the module list" do
    assert [] |> index(without: @entry_kinds, unchanged: true) |> Sidebar.default_expanded() ==
             MapSet.new(["modules"])
  end

  test "no index at all expands nothing" do
    assert Sidebar.default_expanded(nil) == MapSet.new()
  end

  test "the functions a branch changed lead the sidebar, grouped by module and badged" do
    html = [] |> index() |> render_sidebar(MapSet.new(["changes"]))

    assert html =~ ~s|data-kind="changes"|
    assert before?(html, ~s|data-kind="changes"|, ~s|data-kind="routes"|)
    assert html =~ ~s|Changes<span class="group__count">3</span>|

    assert before?(html, "SampleApp.Formatter", "SampleApp.Greeter.Nested")
    assert html =~ ~s|data-change="modified"|
    assert html =~ ~s|data-change="removed"|
    assert html =~ ~s|data-change="added"|
    assert html =~ ~s|phx-value-id="SampleApp.Greeter.Nested.hello/0"|
    assert html =~ "hello/0"
  end

  test "a project the base ref matches has no Changes group" do
    html = [] |> index(unchanged: true) |> render_sidebar(MapSet.new(["changes"]))

    refute html =~ ~s|data-kind="changes"|
    assert html =~ ~s|data-kind="routes"|
  end

  test "the Changes group is one the sidebar can toggle" do
    assert "changes" in Sidebar.group_kinds()
  end

  test "open threads lead the sidebar, under the module and line they were written on" do
    comments =
      by_function([thread(%{id: 7, line: 9, body: "the wrap call is the interesting one"})])

    html = [] |> index() |> render_sidebar(MapSet.new(["comments"]), comments)

    assert html =~ ~s|data-kind="comments"|
    assert before?(html, ~s|data-kind="comments"|, ~s|data-kind="changes"|)
    assert html =~ ~s|Comments<span class="group__count">1</span>|

    assert html =~ ~s|class="group__heading">SampleApp.Greeter</h2>|
    assert html =~ ~s|phx-click="open_comment"|
    assert html =~ ~s|phx-value-id="7"|
    assert html =~ ~s|<span class="entry__where">greet/2 · L9</span>|
    assert html =~ "the wrap call is the interesting one"
  end

  test "a body longer than a row is cut short with an ellipsis" do
    body = String.duplicate("a", 61)
    comments = by_function([thread(%{body: body})])
    html = [] |> index() |> render_sidebar(MapSet.new(["comments"]), comments)

    assert html =~ String.duplicate("a", 60) <> "…"
    refute html =~ body
  end

  test "a thread on a function the index has lost is listed muted" do
    comments = by_function([thread(%{function_id: "SampleApp.Gone.vanished/1"})])
    html = [] |> index() |> render_sidebar(MapSet.new(["comments"]), comments)

    assert html =~ ~s|entry entry--comment entry--orphan|
    assert html =~ ~s|<span class="entry__where">vanished/1 · L9</span>|
  end

  test "a project whose every thread is resolved has no Comments group" do
    comments = by_function([thread(%{resolved: true})])
    html = [] |> index() |> render_sidebar(MapSet.new(["comments"]), comments)

    refute html =~ ~s|data-kind="comments"|
    assert html =~ ~s|data-kind="changes"|
  end

  test "the Comments group is one the sidebar can toggle, and opens while a thread is open" do
    assert "comments" in Sidebar.group_kinds()

    index = index([])
    assert index |> Sidebar.default_expanded(1) |> MapSet.member?("comments")
    refute index |> Sidebar.default_expanded(0) |> MapSet.member?("comments")
    refute index |> Sidebar.default_expanded() |> MapSet.member?("comments")
  end

  test "a review with changes opens them alongside whatever else opens" do
    expanded = Sidebar.default_expanded(index([]))

    assert MapSet.member?(expanded, "changes")
    assert MapSet.member?(expanded, "routes")

    refute [] |> index(unchanged: true) |> Sidebar.default_expanded() |> MapSet.member?("changes")
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
      |> then(&if(opts[:unchanged], do: unchanged(&1), else: &1))

    {:ok, index} = Index.from_document(document)
    index
  end

  # A review run without `--base` compares nothing: every function is unchanged and no
  # function the base alone had is carried over.
  defp unchanged(document) do
    Map.update!(document, "functions", fn records ->
      records
      |> Enum.reject(& &1["removed"])
      |> Enum.map(&Map.put(&1, "change", "unchanged"))
    end)
  end

  defp render_sidebar(index, expanded \\ MapSet.new(["routes"]), comments \\ %{}) do
    render_component(&Sidebar.entry_groups/1,
      index: index,
      comments: comments,
      expanded: expanded,
      expanded_module: nil
    )
  end

  defp thread(attrs) do
    Map.merge(
      %{
        id: 1,
        function_id: @greet,
        side: "new",
        line: 9,
        end_line: nil,
        snippet: nil,
        body: "the default argument hides an arity",
        author: "human",
        created_at: "2026-09-17T00:00:00Z",
        resolved: false,
        replies: []
      },
      attrs
    )
  end

  defp by_function(threads),
    do: Enum.group_by(threads, & &1.function_id)

  defp before?(html, first, second) do
    {start, _length} = :binary.match(html, first)
    {later, _length} = :binary.match(html, second)
    start < later
  end
end
