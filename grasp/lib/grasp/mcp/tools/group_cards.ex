defmodule Grasp.MCP.Tools.GroupCards do
  @moduledoc """
  Frame a set of cards already open, so the canvas draws them apart from everything else:
  the group gets a section of its own, laid out from its own left edge. A `title` is drawn
  over the frame and joins these cards to the group already carrying it; without one the
  cards are framed under a new group with no title, which `rename_group` can name later.

  Use one group per flow whenever the reader is being shown several — "the deposit path and
  the withdrawal path" is two groups, not one canvas of cards to be told apart by reading
  them. A card belongs to one group at a time, so naming a card here takes it out of
  whatever group it was in, and a group left with no cards is gone. Grouping moves no card
  between callers and hides nothing: it is the frame drawn round cards, and the name over it.
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

    field(:title, :string,
      description:
        "The name to draw over the group; cards already under it are joined by these. " <>
          "Omit to frame the cards under a group with no title"
    )

    field(:card_ids, {:list, :integer},
      required: true,
      description: "Ids of the cards to put in the group"
    )
  end

  @impl true
  def execute(%{session: session, card_ids: card_ids} = params, frame) do
    case Tools.fetch_cards(session, card_ids) do
      {:ok, _cards} ->
        Tools.reply(frame, Forest.to_map(group(session, Map.get(params, :title), card_ids)))

      {:error, reason} ->
        Tools.error(frame, reason)
    end
  end

  # A title is trimmed before it reaches the session, since a group is found again by an
  # exact title match and a padded one could never be found.
  defp group(session, nil, card_ids), do: Session.new_group(session, nil, card_ids)

  defp group(session, title, card_ids) when is_binary(title) do
    case String.trim(title) do
      "" -> Session.new_group(session, nil, card_ids)
      trimmed -> Session.group_cards(session, trimmed, card_ids)
    end
  end
end
