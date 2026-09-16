defmodule Grasp.MCP.Tools.GroupCards do
  @moduledoc """
  Frame a set of cards already open under a title, so the canvas draws them apart from
  everything else: the group gets a section of its own, laid out from its own left edge.

  Use one group per flow whenever the reader is being shown several — "the deposit path and
  the withdrawal path" is two groups, not one canvas of cards to be told apart by reading
  them. A card belongs to one group at a time, so naming a card here takes it out of
  whatever group it was in, and a group left with no cards is gone. Grouping moves no card
  between callers and hides nothing: it is a name over cards and the frame drawn round them.
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
      required: true,
      description: "The name to draw over the group; cards already under it are joined by these"
    )

    field(:card_ids, {:list, :integer},
      required: true,
      description: "Ids of the cards to put in the group"
    )
  end

  @impl true
  def execute(%{session: session, title: title, card_ids: card_ids}, frame) do
    with {:ok, title} <- title(title),
         {:ok, _cards} <- Tools.fetch_cards(session, card_ids) do
      Tools.reply(frame, Forest.to_map(Session.group_cards(session, title, card_ids)))
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
