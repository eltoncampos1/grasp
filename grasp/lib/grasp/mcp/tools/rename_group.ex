defmodule Grasp.MCP.Tools.RenameGroup do
  @moduledoc """
  Rename a group already drawn on the canvas. Its cards stay where they are and it keeps its
  id; only the title over the frame changes. Omitting the title clears it, leaving the frame
  standing with no name.

  Reach for this when the title stopped describing what the frame ended up holding — the
  flow grew a step, or the reader called it something else — and to name a group that was
  framed without a title. Putting the same cards through `group_cards` under another title
  draws the same picture but builds a different group, so every id already quoted for that
  group — a card's `group`, a `sections` entry — then names one that is gone.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  schema do
    field(:session, :string,
      default: "default",
      description:
        "The review session to act on — letters, digits, `-` and `_`, up to 40 of them; " <>
          "default `default`, which the page at `/` shows"
    )

    field(:group_id, :integer,
      required: true,
      description: "Id of the group to rename, as `groups` in any session reply carries it"
    )

    field(:title, :string,
      description: "The name to draw over the group from now on; omit to leave it with none"
    )
  end

  @impl true
  def execute(%{session: session, group_id: group_id} = params, frame) do
    case Tools.fetch_group(session, group_id) do
      {:ok, _group} ->
        forest = Session.rename_group(session, group_id, Map.get(params, :title))
        Tools.reply(frame, Forest.to_map(forest))

      {:error, reason} ->
        Tools.error(frame, reason)
    end
  end
end
