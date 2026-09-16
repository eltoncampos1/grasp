defmodule Grasp.MCP.Tools.SearchFunctions do
  @moduledoc """
  Find functions in the indexed project by name. Ranks an exact `Module.fun/arity` id
  first, then ids containing the query, then ids the query's characters run through in
  order, so `walcre` still finds `SampleApp.Wallets.credit/3`.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:query, :string, required: true, description: "Part of a module, function or id")

    field(:limit, :integer,
      default: 20,
      min: 1,
      max: 100,
      description: "How many results to return; default 20, maximum 100"
    )
  end

  @impl true
  def execute(params, frame) do
    case Tools.index() do
      {:error, response} ->
        {:reply, response, frame}

      {:ok, index} ->
        results =
          index
          |> Index.search(params.query, params.limit)
          |> Enum.map(
            &%{
              "id" => &1["id"],
              "kind" => &1["kind"],
              "file" => &1["file"],
              "line" => &1["span"]["start_line"],
              "change" => &1["change"]
            }
          )

        Tools.reply(frame, %{"results" => results})
    end
  end
end
