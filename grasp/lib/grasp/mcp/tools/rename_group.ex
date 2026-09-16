defmodule Grasp.MCP.Tools.RenameGroup do
  @moduledoc """
  Rename a group already drawn on the canvas. Its cards stay where they are and it keeps its
  id; only the title over the frame changes.

  Reach for this when the title stopped describing what the frame ended up holding — the
  flow grew a step, or the reader called it something else. Putting the same cards through
  `group_cards` under another title draws the same picture but builds a different group, so
  every id already quoted for that group — a card's `group`, a `sections` entry — then names
  one that is gone. A blank title is refused: a frame is always drawn with a name.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  schema do
    field(:session, :string,
      default: "default",
      description: "The review session to act on; default `default`, which the page at `/` shows"
    )

    field(:group_id, :integer,
      required: true,
      description: "Id of the group to rename, as `groups` in any session reply carries it"
    )

    field(:title, :string,
      required: true,
      description: "The name to draw over the group from now on"
    )
  end

  @impl true
  def execute(%{session: session, group_id: group_id, title: title}, frame) do
    with {:ok, title} <- title(title),
         {:ok, _group} <- Tools.fetch_group(session, group_id) do
      Tools.reply(frame, Forest.to_map(Session.rename_group(session, group_id, title)))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp title(title) do
    case String.trim(title) do
      "" -> {:error, "title is required"}
      trimmed -> {:ok, trimmed}
    end
  end
end
