defmodule Grasp.MCP.Tools.FocusCard do
  @moduledoc """
  Focus a card, which is how the viewer scrolls it into view — use it to say "look here"
  while walking someone through a tree of cards you have already opened.
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

    field(:card_id, :integer, required: true, description: "Id of the card to focus")
  end

  @impl true
  def execute(%{session: session, card_id: card_id}, frame) do
    :ok = Session.ensure(session)

    case Forest.card(Session.get(session), card_id) do
      nil -> Tools.error(frame, "unknown card: #{card_id}")
      _card -> Tools.reply(frame, Forest.to_map(Session.focus(session, card_id)))
    end
  end
end
