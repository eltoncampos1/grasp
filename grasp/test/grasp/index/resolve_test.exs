defmodule Grasp.Index.ResolveTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Resolve

  @show "SampleAppWeb.GreetController.show/2"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @range %{"start" => [3, 9], "end" => [3, 21]}

  describe "refresh/2" do
    test "resolves a kept record's route sites against routes that appear" do
      record = json(calls: [], route_sites: [site("GET", ["greet", "bob"])])

      assert %{"calls" => []} = Resolve.refresh(record, [])

      assert %{"calls" => [call]} = Resolve.refresh(record, [route("GET", "/greet/:name", @show)])

      assert call == %{
               "target" => @show,
               "kind" => "route",
               "range" => @range,
               "route" => %{"verb" => "GET", "path" => "/greet/:name"}
             }
    end

    test "drops a route call whose route is gone" do
      record = json(calls: [route_call()], route_sites: [site("GET", ["greet", "bob"])])
      assert %{"calls" => []} = Resolve.refresh(record, [])
    end

    test "keeps the record's route sites" do
      sites = [site("GET", ["greet", "bob"])]
      assert %{"route_sites" => ^sites} = Resolve.refresh(json(calls: [], route_sites: sites), [])
    end

    test "reverts an enqueue call whose worker is gone, and draws it again when it is back" do
      enqueue = %{
        "target" => @perform,
        "kind" => "enqueue",
        "range" => @range,
        "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"},
        "via" => %{"target" => "SampleApp.Workers.Mailer.new/1", "kind" => "remote"}
      }

      record = json(calls: [enqueue], route_sites: [])

      assert %{"calls" => [reverted]} = Resolve.refresh(record, [])

      assert reverted == %{
               "target" => "SampleApp.Workers.Mailer.new/1",
               "kind" => "remote",
               "range" => @range
             }

      assert %{"calls" => [^enqueue]} = Resolve.refresh(record, [worker("mail")])

      assert %{"calls" => [%{"job" => %{"queue" => "later"}}]} =
               Resolve.refresh(record, [worker("later")])
    end

    test "leaves a plain call, and a call's position among the others, alone" do
      first = %{
        "target" => "SampleApp.Greeter.greet/1",
        "kind" => "remote",
        "range" => %{"start" => [1, 1], "end" => [1, 6]}
      }

      last = %{
        "target" => "SampleApp.Greeter.greet/2",
        "kind" => "remote",
        "range" => %{"start" => [9, 1], "end" => [9, 6]}
      }

      record =
        json(calls: [first, route_call(), last], route_sites: [site("GET", ["greet", "bob"])])

      assert %{"calls" => [^first, %{"kind" => "route"}, ^last]} =
               Resolve.refresh(record, [route("GET", "/greet/:name", @show)])
    end

    test "is idempotent" do
      entries = [route("GET", "/greet/:name", @show), worker("mail")]
      record = json(calls: [route_call()], route_sites: [site("GET", ["greet", "bob"])])
      once = Resolve.refresh(record, entries)
      assert Resolve.refresh(once, entries) == once
    end

    test "leaves a record written without its inputs as it is" do
      legacy = Map.delete(json(calls: [route_call()], route_sites: []), "route_sites")
      assert Resolve.refresh(legacy, []) == legacy
    end

    test "reads a dynamic segment back from the document" do
      record = json(calls: [], route_sites: [site("GET", ["greet", nil])])

      assert %{"calls" => [%{"kind" => "route"}]} =
               Resolve.refresh(record, [route("GET", "/greet/:name", @show)])
    end
  end

  test "resolve/2 runs routes then jobs over records" do
    record = %{
      id: "SampleAppWeb.GreetHTML.show/1",
      calls: [
        %{
          target: "SampleApp.Workers.Mailer.new/1",
          kind: :remote,
          range: %{start: {5, 1}, end: {5, 6}}
        }
      ],
      route_sites: [%{verb: "GET", path: ["greet", "bob"], range: %{start: {3, 9}, end: {3, 21}}}]
    }

    assert [%{calls: calls, route_sites: [_site]}] =
             Resolve.resolve([record], [route("GET", "/greet/:name", @show), worker("mail")])

    assert Enum.map(calls, &{&1.target, &1.kind}) == [{@show, :route}, {@perform, :enqueue}]
  end

  defp json(calls: calls, route_sites: sites),
    do: %{
      "id" => "SampleAppWeb.GreetHTML.show/1",
      "file" => "lib/sample_app_web/greet_html/show.html.heex",
      "calls" => calls,
      "route_sites" => sites
    }

  defp site(verb, path), do: %{"verb" => verb, "path" => path, "range" => @range}

  defp route_call,
    do: %{
      "target" => @show,
      "kind" => "route",
      "range" => @range,
      "route" => %{"verb" => "GET", "path" => "/greet/:name"}
    }

  defp route(verb, path, target),
    do: %{
      "kind" => "route",
      "label" => "#{verb} #{path}",
      "target" => target,
      "meta" => %{"verb" => verb, "path" => path}
    }

  defp worker(queue),
    do: %{
      "kind" => "oban_worker",
      "label" => @perform,
      "target" => @perform,
      "meta" => %{"queue" => queue}
    }
end
