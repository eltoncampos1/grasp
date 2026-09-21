defmodule Grasp.Index.RoutesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Routes

  @show "SampleAppWeb.GreetController.show/2"
  @create "SampleAppWeb.GreetController.create/2"
  @mount "SampleAppWeb.HelloLive.mount/3"
  @user "SampleAppWeb.UserController.show/2"
  @new_user "SampleAppWeb.UserController.new/2"
  @files "SampleAppWeb.FileController.show/2"

  test "resolves a literal path against the route whose parameter it fills" do
    assert [call] = calls(site("GET", ["greet", "bob"]))

    assert call == %{
             target: @show,
             kind: :route,
             range: %{start: {1, 9}, end: {1, 21}},
             route: %{verb: "GET", path: "/greet/:name"}
           }
  end

  test "resolves a segment the template computes against any one route parameter" do
    assert [%{target: @show}] = calls(site("GET", ["greet", :dynamic]))
  end

  test "tells two routes of one path apart by the verb the site was written with" do
    assert [%{target: @create, route: %{path: "/greet"}}] = calls(site("POST", ["greet"]))
  end

  test "resolves a path a live view answers to" do
    assert [%{target: @mount}] = calls(site("GET", ["hello"]))
  end

  test "prefers the route with the fewest dynamic segments over the one listed first" do
    assert [%{target: @new_user}] = calls(site("GET", ["users", "new"]))
    assert [%{target: @user}] = calls(site("GET", ["users", "7"]))
  end

  test "matches a glob against every segment left, and against none" do
    assert [%{target: @files}] = calls(site("GET", ["files", "a", "b"]))
    assert [%{target: @files}] = calls(site("GET", ["files"]))
  end

  test "drops a site no route answers to" do
    assert calls(site("GET", ["greet"])) == []
    assert calls(site("GET", ["nowhere"])) == []
  end

  test "returns a record with no route sites unchanged, and without the key" do
    record = %{id: "SampleApp.Greeter.greet/2", calls: []}

    assert Routes.resolve([record], entries()) == [record]
    assert Routes.resolve([Map.put(record, :route_sites, [])], entries()) == [record]
  end

  test "keeps a call per site when two of them reach the same action" do
    sites = [
      %{verb: "GET", path: ["greet", "bob"], range: %{start: {1, 9}, end: {1, 21}}},
      %{verb: "GET", path: ["greet", "ann"], range: %{start: {2, 9}, end: {2, 21}}}
    ]

    assert [%{range: %{start: {1, 9}}}, %{range: %{start: {2, 9}}}] = calls(sites)
  end

  test "sorts the route calls into the order the join leaves its calls in" do
    record = %{
      id: "SampleAppWeb.GreetHTML.show/1",
      calls: [
        %{
          target: "SampleApp.Greeter.greet/1",
          kind: :remote,
          range: %{start: {5, 1}, end: {5, 6}}
        }
      ],
      route_sites: [%{verb: "GET", path: ["hello"], range: %{start: {2, 1}, end: {2, 9}}}]
    }

    assert [resolved] = Routes.resolve([record], entries())
    refute Map.has_key?(resolved, :route_sites)

    assert Enum.map(resolved.calls, & &1.target) == [@mount, "SampleApp.Greeter.greet/1"]
  end

  defp site(verb, path),
    do: [%{verb: verb, path: path, range: %{start: {1, 9}, end: {1, 21}}}]

  defp calls(route_sites) do
    record = %{id: "SampleAppWeb.GreetHTML.show/1", calls: [], route_sites: route_sites}

    [resolved] = Routes.resolve([record], entries())
    refute Map.has_key?(resolved, :route_sites)
    resolved.calls
  end

  # The router's routes as the document holds them: sorted by label, so `/users/:id`
  # stands before `/users/new` and only specificity can tell the two apart. The worker is
  # there to be ignored.
  defp entries do
    [
      entry("route", "GET", "/greet/:name", @show),
      entry("route", "POST", "/greet", @create),
      entry("live_route", "GET", "/hello", @mount),
      entry("route", "GET", "/users/:id", @user),
      entry("route", "GET", "/users/new", @new_user),
      entry("route", "GET", "/files/*path", @files),
      %{
        "kind" => "oban_worker",
        "label" => "SampleApp.Workers.Mailer.perform/1",
        "target" => "SampleApp.Workers.Mailer.perform/1",
        "meta" => %{"queue" => "mail"}
      }
    ]
  end

  defp entry(kind, verb, path, target) do
    %{
      "kind" => kind,
      "label" => "#{verb} #{path}",
      "target" => target,
      "meta" => %{"verb" => verb, "path" => path, "router" => "SampleAppWeb.Router"}
    }
  end
end
