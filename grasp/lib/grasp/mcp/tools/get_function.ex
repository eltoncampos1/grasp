defmodule Grasp.MCP.Tools.GetFunction do
  @moduledoc """
  Read one function of the indexed project: its source, span, calls, the ids that call it,
  the ids it calls, and the entry points that reach it. Accepts any arity a definition with
  default arguments answers to.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:id, :string, required: true, description: "A function id, `Module.fun/arity`")
  end

  @impl true
  def execute(%{id: id}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Index.fetch_function(index, id) do
      entry_points =
        index
        |> Index.entry_points_for(record["id"])
        |> Enum.map(&Map.take(&1, ["kind", "label"]))

      body =
        record
        |> Map.drop(["base_source"])
        |> Map.merge(%{
          "callers" => Index.callers(index, record["id"]),
          "callees" => Index.callees(index, record["id"]),
          "entry_points" => entry_points
        })

      Tools.reply(frame, body)
    else
      {:error, response} -> {:reply, response, frame}
      :error -> Tools.error(frame, "unknown function: #{id}")
    end
  end
end
