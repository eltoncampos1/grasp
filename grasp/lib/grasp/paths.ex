defmodule Grasp.Paths do
  @moduledoc """
  Shortest call paths over an index, for agents building a tour or explaining a flow.

  Breadth-first over paths: the queue holds whole paths, a `{node, depth}` set stops a node
  from being re-entered at a greater depth while still letting two same-length paths share a
  node, and a visit budget bounds the walk on a large graph. Results are shortest first.

  A walk stops at the goal — a longer route through a node already reached adds nothing —
  and the seed is never a goal, so `between/4` on one function reports no path rather than a
  path of length one. Ids are canonical: the seed is resolved through the reader's
  default-argument aliases, and `Grasp.Index.callers/2` and `callees/2` already are.
  """

  alias Grasp.Index

  @type result :: %{paths: [[String.t()]], truncated?: boolean()}
  @type opts :: [max_depth: pos_integer(), limit: pos_integer(), budget: pos_integer()]

  @defaults [max_depth: 6, limit: 5, budget: 20_000]

  @doc """
  Paths from `from` to `to` following callees.

  Each path reads in call order, `from` first. `max_depth` (default 6) bounds the hops a
  path may take — a path of n ids has n-1 hops — `limit` (default 5) the paths collected,
  and `budget` (default 20_000) the nodes visited; an exhausted budget comes back as
  `truncated?: true`. A `from` the index does not define has no paths.
  """
  @spec between(Index.t(), String.t(), String.t(), opts()) :: result()
  def between(%Index{} = index, from, to, opts) do
    to = canonical(index, to)

    search(index, canonical(index, from), &Index.callees(index, &1), &(&1 == to), opts)
  end

  @doc """
  Paths from any entry-point target down to `to`, found by walking callers backwards.

  Each path reads in call order, the entry point first, and takes the same options as
  `between/4`. A function no entry point reaches within `max_depth` hops has no paths.
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

    %{
      result
      | paths: result.paths |> Enum.map(&Enum.reverse/1) |> Enum.sort_by(&{length(&1), &1})
    }
  end

  defp search(%Index{} = index, seed, next, goal?, opts) do
    opts = Keyword.merge(@defaults, opts)

    case Index.fetch_function(index, seed) do
      {:ok, _record} ->
        {paths, truncated?} =
          walk(
            :queue.in([seed], :queue.new()),
            %{seed => 0},
            next,
            goal?,
            opts,
            [],
            opts[:budget]
          )

        %{paths: Enum.sort_by(paths, &{length(&1), &1}), truncated?: truncated?}

      :error ->
        %{paths: [], truncated?: false}
    end
  end

  defp walk(queue, seen, next, goal?, opts, found, budget) do
    cond do
      length(found) >= opts[:limit] ->
        {found, false}

      :queue.is_empty(queue) ->
        {found, false}

      budget <= 0 ->
        {found, true}

      true ->
        {{:value, path}, queue} = :queue.out(queue)
        visit(path, queue, seen, next, goal?, opts, found, budget)
    end
  end

  defp visit([head | _] = path, queue, seen, next, goal?, opts, found, budget) do
    depth = length(path)

    cond do
      goal?.(head) and depth > 1 ->
        walk(queue, seen, next, goal?, opts, [Enum.reverse(path) | found], budget - 1)

      depth - 1 >= opts[:max_depth] ->
        walk(queue, seen, next, goal?, opts, found, budget - 1)

      true ->
        {queue, seen} =
          head
          |> next.()
          |> Enum.sort()
          |> Enum.reduce({queue, seen}, fn node, {queue, seen} ->
            if node in path or Map.get(seen, node, depth) < depth do
              {queue, seen}
            else
              {:queue.in([node | path], queue), Map.put_new(seen, node, depth)}
            end
          end)

        walk(queue, seen, next, goal?, opts, found, budget - 1)
    end
  end

  defp canonical(%Index{} = index, id) do
    case Index.fetch_function(index, id) do
      {:ok, record} -> record["id"]
      :error -> id
    end
  end
end
