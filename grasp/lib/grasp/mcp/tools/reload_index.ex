defmodule Grasp.MCP.Tools.ReloadIndex do
  @moduledoc """
  Reload the index file the viewer watches and report what it now holds: the path, how many
  functions it carries, how many of them the branch changed, and the git refs it was built
  against.

  Call it as soon as `mix grasp.index` finishes — after an edit, or after checking out
  another branch — and before `list_changes` or any other read. The viewer picks a rewritten
  file up on its own within a couple of seconds, so a read taken in between answers from the
  index the rebuild replaced; reloading first makes the next read describe the code on disk.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.IndexStore
  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case IndexStore.reload() do
      :ok ->
        index = IndexStore.get()
        git = index.git || %{}

        Tools.reply(frame, %{
          "path" => IndexStore.path(),
          "functions" => length(Index.functions(index)),
          "changed" => length(Index.changed_functions(index)),
          "base_ref" => git["base_ref"],
          "branch" => git["branch"],
          "head" => git["head"]
        })

      {:error, :no_path} ->
        Tools.error(frame, "no index path is being watched")

      {:error, reason} ->
        Tools.error(frame, "could not load the index: " <> inspect(reason))
    end
  end
end
