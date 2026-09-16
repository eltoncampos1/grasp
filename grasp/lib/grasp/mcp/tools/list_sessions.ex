defmodule Grasp.MCP.Tools.ListSessions do
  @moduledoc "List the review sessions currently running in the viewer, by name."

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame), do: Tools.reply(frame, %{"sessions" => Grasp.Session.list()})
end
