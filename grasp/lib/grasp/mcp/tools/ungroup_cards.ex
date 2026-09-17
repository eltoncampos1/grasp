defmodule Grasp.MCP.Tools.UngroupCards do
  @moduledoc """
  Take cards out of the group they are in, returning them to the untitled part of the
  canvas. A group whose last card leaves is gone with it, frame and title both.

  This unpicks a grouping; to move cards from one flow to another, name them in
  `group_cards` under the other flow's title instead, which takes them out of the first.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  @session_field Tools.session_field_description()

  schema do
    field(:session, :string,
      default: "default",
      description: @session_field
    )

    field(:card_ids, {:list, :integer},
      required: true,
      description: "Ids of the cards to take out of their groups"
    )
  end

  @impl true
  def execute(%{card_ids: []}, frame),
    do: Tools.error(frame, "card_ids must name at least one card")

  def execute(%{session: session, card_ids: card_ids}, frame) do
    case Tools.fetch_cards(session, card_ids) do
      {:ok, _cards} ->
        Tools.reply(frame, Forest.to_map(Session.ungroup_cards(session, card_ids)))

      {:error, reason} ->
        Tools.error(frame, reason)
    end
  end
end
