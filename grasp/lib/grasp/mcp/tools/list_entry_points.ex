defmodule Grasp.MCP.Tools.ListEntryPoints do
  @moduledoc """
  List the indexed project's entry points — routes, LiveView and GenServer callbacks, Oban
  workers — each with the function it dispatches to. A good first call for finding where a
  request or a job enters the code.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:kind, :string,
      description: "Keep only this kind, lowercase, e.g. `route` or `oban_worker`"
    )

    field(:query, :string, description: "Case-insensitive substring of the label or the target")

    field(:limit, :integer,
      default: 100,
      min: 1,
      max: 500,
      description: "How many entry points to return; default 100, maximum 500"
    )
  end

  @impl true
  def execute(params, frame) do
    case Tools.index() do
      {:error, response} ->
        {:reply, response, frame}

      {:ok, index} ->
        kind = params |> Map.get(:kind) |> downcase()
        query = params |> Map.get(:query) |> downcase()

        matches =
          index
          |> Index.entry_points()
          |> Enum.filter(fn entry ->
            (is_nil(kind) or downcase(entry["kind"]) == kind) and
              (is_nil(query) or
                 String.contains?(downcase(entry["label"]) || "", query) or
                 String.contains?(downcase(entry["target"]) || "", query))
          end)

        Tools.reply(frame, %{
          "total" => length(matches),
          "entry_points" =>
            matches |> Enum.take(params.limit) |> Enum.map(&Map.take(&1, ~w(kind label target)))
        })
    end
  end

  defp downcase(nil), do: nil
  defp downcase(string), do: String.downcase(string)
end
