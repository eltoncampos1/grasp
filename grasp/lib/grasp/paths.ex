defmodule Grasp.Paths do
  @moduledoc """
  Shortest call paths over an index, for agents building a tour or explaining a flow.

  Breadth-first over paths: the queue holds whole paths, a `{node, depth}` set stops a node
  from being re-entered at a greater depth while still letting two same-length paths share a
  node, and a visit budget bounds the walk on a large graph. Results are shortest first.

  The walk reports one hop count: the first goal fixes the horizon, the rest of that layer is
  drained, and nothing deeper is expanded — so a longer detour to a goal already reached the
  short way is never listed. Draining the whole layer is what lets `limit` cut in the order
  the result is documented in rather than in the order the walk happened to find paths.

  A walk stops at the goal, and the seed is never a goal, so `between/4` on one function
  reports no path rather than a path of length one. Ids are canonical: the seed is resolved
  through the reader's default-argument aliases, and `Grasp.Index.callers/2` and `callees/2`
  already are.
  """

  alias Grasp.Index

  @type result :: %{paths: [[String.t()]], truncated?: boolean()}
  @type opts :: [max_depth: pos_integer(), limit: pos_integer(), budget: pos_integer()]

  @defaults [max_depth: 6, limit: 5, budget: 20_000]

  @doc """
  Paths from `from` to `to` following callees.

  Each path reads in call order, `from` first, and they are listed shortest first, ties by
  the path's ids ascending. `max_depth` (default 6) bounds the hops a path may take — a path
  of n ids has n-1 hops — `limit` (default 5) the paths returned, and `budget` (default
  20_000) the nodes visited; an exhausted budget comes back as `truncated?: true`. A `from`
  the index does not define has no paths.
  """
  @spec between(Index.t(), String.t(), String.t(), opts()) :: result()
  def between(%Index{} = index, from, to, opts) do
    to = canonical(index, to)

    index
    |> search(canonical(index, from), &Index.callees(index, &1), &(&1 == to), opts)
    |> rank(opts)
  end

  @doc """
  Paths from any entry-point target down to `to`, found by walking callers backwards.

  Each path reads in call order, the entry point first, and takes the same options as
  `between/4`. A path stops at the first entry point it reaches, so an entry point called by
  another one is reported on its own rather than behind the one above it. A function no entry
  point reaches within `max_depth` hops has no paths.
  """
  @spec to_entry_points(Index.t(), String.t(), opts()) :: result()
  def to_entry_points(%Index{} = index, to, opts) do
    entries = index |> Index.entry_points() |> MapSet.new(&canonical(index, &1["target"]))

    result =
      search(
        index,
        canonical(index, to),
        &Index.callers(index, &1),
        &MapSet.member?(entries, &1),
        opts
      )

    rank(%{result | paths: Enum.map(result.paths, &Enum.reverse/1)}, opts)
  end

  defp search(%Index{} = index, seed, next, goal?, opts) do
    opts = Keyword.merge(@defaults, opts)

    case Index.fetch_function(index, seed) do
      {:ok, _record} ->
        state = %{
          next: next,
          goal?: goal?,
          max_depth: opts[:max_depth],
          budget: opts[:budget],
          seen: %{seed => 0},
          found: [],
          horizon: opts[:max_depth]
        }

        walk(:queue.in([seed], :queue.new()), state)

      :error ->
        %{paths: [], truncated?: false}
    end
  end

  defp walk(queue, state) do
    cond do
      :queue.is_empty(queue) ->
        %{paths: state.found, truncated?: false}

      state.budget <= 0 ->
        %{paths: state.found, truncated?: true}

      true ->
        {{:value, path}, queue} = :queue.out(queue)
        visit(path, queue, %{state | budget: state.budget - 1})
    end
  end

  defp visit([head | _] = path, queue, state) do
    hops = length(path) - 1

    cond do
      hops > state.horizon ->
        walk(queue, state)

      state.goal?.(head) and hops > 0 ->
        walk(queue, %{state | found: [Enum.reverse(path) | state.found], horizon: hops})

      hops >= state.horizon ->
        walk(queue, state)

      true ->
        depth = hops + 1

        {queue, seen} =
          Enum.reduce(state.next.(head), {queue, state.seen}, fn node, {queue, seen} ->
            if node in path or Map.get(seen, node, depth) < depth do
              {queue, seen}
            else
              {:queue.in([node | path], queue), Map.put_new(seen, node, depth)}
            end
          end)

        walk(queue, %{state | seen: seen})
    end
  end

  defp rank(result, opts) do
    limit = Keyword.merge(@defaults, opts)[:limit]

    %{result | paths: result.paths |> Enum.sort_by(&{length(&1), &1}) |> Enum.take(limit)}
  end

  defp canonical(%Index{} = index, id) do
    case Index.fetch_function(index, id) do
      {:ok, record} -> record["id"]
      :error -> id
    end
  end
end
