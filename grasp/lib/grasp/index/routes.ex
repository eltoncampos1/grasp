defmodule Grasp.Index.Routes do
  @moduledoc """
  Turns the route sites a record carries into calls on the controller action or LiveView
  the router maps each one to.

  A route site is a verb and a list of path segments — what `Grasp.Index.Extract` read out
  of an `href`, a form's `action`, a `navigate`, an `hx-post` or a `~p` sigil. The routes
  it is matched against are the `route` and `live_route` entry points, which carry the
  verb and the path the router declared; every other kind of entry point is ignored.

  A route's path is split the way a site's is. A segment written `:name` matches any one
  segment, one written `*rest` matches every segment left, including none, and must be the
  last; anything else matches the same text, or a `:dynamic` segment, which is a segment
  the template computes and no reader of the source can know.

  Several routes can match one site, and the most specific wins: the fewest dynamic
  segments, counting a glob as two and a parameter as one, so `/users/new` beats
  `/users/:id` and `/users/:id` beats `/files/*path`. Declaration order cannot be the
  tie-breaker Phoenix itself uses, because the entry points reach this module sorted by
  label rather than in the order the router wrote them; where specificity is equal, the
  first entry in the list wins, which is at least a stable answer.

  A site no route answers to becomes nothing: a link out to another site, a path served by
  a plug the index does not hold, and a path this pass reads wrongly all look the same
  here, and a call into a function no one named would be worse than a missing edge.

  A record keeps its sites once they are resolved. They are the input this pass reads, and
  the document carries them so an update can match them against the routes it finds rather
  than against the routes the build that wrote the record found.
  """

  @route_kinds ["route", "live_route"]

  @doc """
  Appends a call of kind `:route` to every record for each route site that resolves.

  `entries` are entry points in the JSON shape the document holds them in, as
  `Grasp.Index.Builder.entry_point_json/1` writes them. Records keep their `:route_sites`:
  the document carries them so an update can resolve them again.
  """
  @spec resolve([map()], [map()]) :: [map()]
  def resolve(records, entries) do
    routes = entries |> Enum.filter(&(&1["kind"] in @route_kinds)) |> Enum.flat_map(&route/1)

    Enum.map(records, &resolve_record(&1, routes))
  end

  defp route(%{"target" => target, "meta" => %{"verb" => verb, "path" => path}})
       when is_binary(target) and is_binary(verb) and is_binary(path) do
    segments = for segment <- String.split(path, "/"), segment != "", do: segment

    [
      %{
        target: target,
        verb: verb,
        path: path,
        segments: segments,
        specificity: specificity(segments)
      }
    ]
  end

  defp route(_entry), do: []

  defp specificity(segments) do
    Enum.reduce(segments, 0, fn
      "*" <> _rest, score -> score + 2
      ":" <> _rest, score -> score + 1
      _literal, score -> score
    end)
  end

  defp resolve_record(record, routes) do
    case Map.get(record, :route_sites, []) do
      [] ->
        record

      sites ->
        calls = record.calls ++ Enum.flat_map(sites, &call(&1, routes))

        Map.put(
          record,
          :calls,
          calls |> Enum.uniq() |> Enum.sort_by(&{&1.range.start, &1.target, &1.kind})
        )
    end
  end

  defp call(site, routes) do
    case Enum.filter(routes, &(&1.verb == site.verb and matches?(&1.segments, site.path))) do
      [] ->
        []

      matching ->
        route = Enum.min_by(matching, & &1.specificity)

        [
          %{
            target: route.target,
            kind: :route,
            range: site.range,
            route: %{verb: route.verb, path: route.path}
          }
        ]
    end
  end

  # A site's segment is text the source wrote or `:dynamic`, a segment it computes.
  defp matches?([], []), do: true
  defp matches?(["*" <> _rest], _segments), do: true
  defp matches?([":" <> _name | route], [_segment | segments]), do: matches?(route, segments)
  defp matches?([_literal | route], [:dynamic | segments]), do: matches?(route, segments)
  defp matches?([literal | route], [literal | segments]), do: matches?(route, segments)
  defp matches?(_route, _segments), do: false
end
