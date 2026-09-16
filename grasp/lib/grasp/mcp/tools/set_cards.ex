defmodule Grasp.MCP.Tools.SetCards do
  @moduledoc """
  Lay out a whole reading of the code at once: replace every card in a review session with
  the tree you describe, so the reviewer sees the path you walked rather than the order you
  walked it in.

  Cards are given parents before children. `key` is your own name for a card, and a later
  card hangs under an earlier one by naming it in `parent_key`; a card with no `parent_key`
  starts a new tree. Each card may point at one thing inside it — a call it makes, or a
  range of its lines. Nothing changes unless every card is good.
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

    embeds_many :cards, required: true, description: "The cards to show, parents first" do
      field(:key, :string,
        required: true,
        description: "Your name for this card, which later cards point at through `parent_key`"
      )

      field(:function_id, :string,
        required: true,
        description: "The function the card shows, `Module.fun/arity`"
      )

      field(:parent_key, :string,
        description: "`key` of the card this one hangs under; omit to start a new tree"
      )

      embeds_one :highlight, description: "What to point at inside the card; omit for nothing" do
        field(:call, :string, description: "A call the function makes, to outline")

        field(:lines, {:list, :integer},
          description: "First and last line to shade, both inside the function"
        )
      end
    end
  end

  @impl true
  def execute(%{session: session, cards: cards}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, specs} <- Cards.prepare(index, cards),
         :ok <- Session.ensure(session),
         {:ok, forest} <- Session.set_cards(session, specs) do
      Tools.reply(frame, Forest.to_map(forest))
    else
      # Cards.prepare/2 enforces the rule Forest.replace/1 does, so the unknown parent is
      # unreachable today; it is here so the two drifting apart is an error, not a crash.
      {:error, {:unknown_parent, key}} -> Tools.error(frame, "unknown parent key: #{key}")
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
