defmodule Grasp.MCP.Tools.FocusCard do
  @moduledoc """
  Focus a card, which is how the viewer scrolls it into view — use it to say "look here"
  while walking someone through a graph of cards you have already opened.
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

    field(:card_id, :integer, required: true, description: "Id of the card to focus")
  end

  @impl true
  def execute(%{session: session, card_id: card_id}, frame) do
    case Tools.fetch_card(session, card_id) do
      {:ok, _card} -> Tools.reply(frame, Forest.to_map(Session.focus(session, card_id)))
      {:error, message} -> Tools.error(frame, message)
    end
  end
end
