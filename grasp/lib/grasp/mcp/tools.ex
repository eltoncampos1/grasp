defmodule Grasp.MCP.Tools do
  @moduledoc "Shared plumbing for the MCP tools: the loaded index and JSON/error replies."

  alias Anubis.Server.Response

  @doc "The loaded index, or the tool error every index-reading tool replies with when none is loaded."
  @spec index() :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index, do: index(Grasp.IndexStore.get())

  @doc "`index/0` over a store value, so the no-index reply can be exercised without a store."
  @spec index(Grasp.Index.t() | nil) :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index(nil), do: {:error, Response.error(Response.tool(), "no index loaded")}
  def index(%Grasp.Index{} = index), do: {:ok, index}

  @doc "A JSON tool reply."
  @spec reply(term(), term()) :: {:reply, Response.t(), term()}
  def reply(frame, data), do: {:reply, Response.json(Response.tool(), data), frame}

  @doc "A tool error reply."
  @spec error(term(), String.t()) :: {:reply, Response.t(), term()}
  def error(frame, message), do: {:reply, Response.error(Response.tool(), message), frame}
end
