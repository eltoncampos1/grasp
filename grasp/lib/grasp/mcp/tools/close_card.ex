defmodule Grasp.MCP.Tools.CloseCard do
  @moduledoc """
  Close a card and everything opened under it, so the reviewer is left with the branch that
  matters. Focus moves to the card's parent.
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

    field(:card_id, :integer, required: true, description: "Id of the card to close")
  end

  @impl true
  def execute(%{session: session, card_id: card_id}, frame) do
    :ok = Session.ensure(session)

    case Forest.card(Session.get(session), card_id) do
      nil -> Tools.error(frame, "unknown card: #{card_id}")
      _card -> Tools.reply(frame, Forest.to_map(Session.close(session, card_id)))
    end
  end
end
