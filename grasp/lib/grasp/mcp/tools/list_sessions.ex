defmodule Grasp.MCP.Tools.ListSessions do
  @moduledoc "List the review sessions the viewer is running or has saved, by name."

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame), do: Tools.reply(frame, %{"sessions" => Grasp.Session.list()})
end
