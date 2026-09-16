defmodule Grasp.MCP.Tools.HighlightCard do
  @moduledoc """
  Point at something inside a card already open: outline one of the calls the function
  makes, or shade a range of its lines. A card points at one thing at a time, and an empty
  `highlight` clears it.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Cards
  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  schema do
    field(:session, :string,
      default: "default",
      description: "The review session to act on; default `default`, which the page at `/` shows"
    )

    field(:card_id, :integer, required: true, description: "Id of the card to mark")

    embeds_one :highlight,
      required: true,
      description: "What to point at; an empty object clears the card" do
      field(:call, :string, description: "A call the function makes, to outline")

      field(:lines, {:list, :integer},
        description: "First and last line to shade, both inside the function"
      )
    end
  end

  @impl true
  def execute(%{session: session, card_id: card_id, highlight: asked}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, card} <- Tools.fetch_card(session, card_id),
         {:ok, highlight} <- Cards.validate_highlight(index, card.function_id, asked) do
      Tools.reply(frame, Forest.to_map(Session.set_highlight(session, card_id, highlight)))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
