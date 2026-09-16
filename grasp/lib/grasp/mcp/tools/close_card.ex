defmodule Grasp.MCP.Tools.CloseCard do
  @moduledoc """
  Close one card and the edges touching it, so the reviewer is left with the part of the
  graph that matters. What it called stays on screen, unattached; focus moves to the first
  card that called it, or else to the first card it called.
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
    case Tools.fetch_card(session, card_id) do
      {:ok, _card} -> Tools.reply(frame, Forest.to_map(Session.close(session, card_id)))
      {:error, message} -> Tools.error(frame, message)
    end
  end
end
