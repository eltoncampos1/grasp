defmodule Grasp.MCP.Tools.ListModules do
  @moduledoc """
  List the indexed project's modules with their file and the behaviours they implement.
  Use it to get the shape of the codebase, or to find the module a name belongs to.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:query, :string, description: "Case-insensitive substring of the name or the file")

    field(:limit, :integer,
      default: 200,
      min: 1,
      max: 2000,
      description: "How many modules to return; default 200, maximum 2000"
    )
  end

  @impl true
  def execute(params, frame) do
    case Tools.index() do
      {:error, response} ->
        {:reply, response, frame}

      {:ok, index} ->
        query = params |> Map.get(:query) |> downcase()

        matches =
          index
          |> Index.modules()
          |> Enum.filter(fn module ->
            is_nil(query) or
              String.contains?(downcase(module["name"]) || "", query) or
              String.contains?(downcase(module["file"]) || "", query)
          end)

        Tools.reply(frame, %{
          "total" => length(matches),
          "modules" =>
            matches
            |> Enum.take(params.limit)
            |> Enum.map(
              &%{
                "name" => &1["name"],
                "file" => &1["file"],
                "behaviours" => &1["behaviours"] || []
              }
            )
        })
    end
  end

  defp downcase(nil), do: nil
  defp downcase(string), do: String.downcase(string)
end
