defmodule Grasp.MCP.Server do
  @moduledoc """
  The MCP server exposing the loaded index as read tools.

  Mounted at `/mcp` over Streamable HTTP by `GraspWeb.Router`; one `component` line per
  tool, whose name clients see is the module's basename in snake case.
  """

  use Anubis.Server,
    name: "grasp",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  alias Grasp.MCP.Tools

  component(Tools.SearchFunctions)
  component(Tools.GetFunction)
  component(Tools.GetCallers)
  component(Tools.GetCallees)
  component(Tools.FindPaths)
  component(Tools.ListEntryPoints)
  component(Tools.ListModules)
  component(Tools.ListSessions)
end
