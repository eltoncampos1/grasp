defmodule Grasp.MCP.Tools.FindPaths do
  @moduledoc """
  Trace how a function is reached: shortest call paths down to it from another function,
  or, with no `from`, from whatever entry points reach it — a route, a LiveView callback,
  an Oban worker. Each path reads in call order and carries the entry point it starts at.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools
  alias Grasp.Paths

  schema do
    field(:to, :string, required: true, description: "The function the paths end at")

    field(:from, :string,
      description: "The function the paths start at; entry points are used when omitted"
    )

    field(:max_depth, :integer, default: 6, min: 1, max: 8, description: "Hops a path may take")
    field(:limit, :integer, default: 5, min: 1, max: 20)
  end

  @impl true
  def execute(params, frame) do
    from = Map.get(params, :from)

    with {:ok, index} <- Tools.index(),
         {:ok, _to} <- defined(index, params.to),
         {:ok, _from} <- defined(index, from) do
      opts = [max_depth: params.max_depth, limit: params.limit]

      result =
        if from,
          do: Paths.between(index, from, params.to, opts),
          else: Paths.to_entry_points(index, params.to, opts)

      paths =
        Enum.map(result.paths, fn [head | _] = ids ->
          %{"ids" => ids, "entry" => entry(index, head)}
        end)

      Tools.reply(frame, %{"paths" => paths, "truncated" => result.truncated?})
    else
      {:error, response} -> {:reply, response, frame}
      {:unknown, id} -> Tools.error(frame, "unknown function: #{id}")
    end
  end

  defp defined(_index, nil), do: {:ok, nil}

  defp defined(index, id) do
    case Index.fetch_function(index, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:unknown, id}
    end
  end

  defp entry(index, id) do
    case Index.entry_points_for(index, id) do
      [entry | _] -> Map.take(entry, ["kind", "label"])
      [] -> nil
    end
  end
end
