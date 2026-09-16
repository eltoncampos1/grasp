defmodule Grasp.MCP.Tools.OpenCard do
  @moduledoc """
  Open one function as a card and focus it. With `parent_card_id` the card hangs under that
  card, and the call it was opened from is marked in the parent, exactly as a click in the
  viewer would; without one it starts a new tree. Opening a function that is already a child
  of that card focuses the existing card instead of duplicating it.

  Replies with the whole session plus `card_id`, the id of the card that is now focused.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Grasp.Index
  alias Grasp.MCP.Cards
  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  schema do
    field(:session, :string,
      default: "default",
      description: "The review session to act on; default `default`, which the page at `/` shows"
    )

    field(:function_id, :string,
      required: true,
      description: "The function to open, `Module.fun/arity`"
    )

    field(:parent_card_id, :integer,
      description: "Card to open this one under; omit to start a new tree"
    )

    embeds_one :highlight, description: "What to point at inside the card; omit for nothing" do
      field(:call, :string, description: "A call the function makes, to outline")

      field(:lines, {:list, :integer},
        description: "First and last line to shade, both inside the function"
      )
    end
  end

  @impl true
  def execute(%{session: session, function_id: function_id} = params, frame) do
    asked = Map.get(params, :highlight)

    with {:ok, index} <- Tools.index(),
         {:ok, record} <- fetch(index, function_id),
         {:ok, highlight} <- Cards.validate_highlight(index, record["id"], asked),
         :ok <- Session.ensure(session),
         {:ok, forest} <- open(session, index, Map.get(params, :parent_card_id), record) do
      card_id = forest.focus
      forest = if asked, do: Session.set_highlight(session, card_id, highlight), else: forest

      Tools.reply(frame, Map.put(Forest.to_map(forest), "card_id", card_id))
    else
      {:error, %Response{} = response} -> {:reply, response, frame}
      {:error, message} when is_binary(message) -> Tools.error(frame, message)
    end
  end

  defp fetch(index, function_id) do
    case Index.fetch_function(index, function_id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, "unknown function: #{function_id}"}
    end
  end

  defp open(session, _index, nil, record), do: {:ok, Session.open_root(session, record["id"])}

  defp open(session, index, parent_card_id, record) do
    case Forest.card(Session.get(session), parent_card_id) do
      nil ->
        {:error, "unknown card: #{parent_card_id}"}

      parent ->
        opened_by = Cards.opened_by(index, parent.function_id, record["id"])
        {:ok, Session.open_child(session, parent_card_id, record["id"], opened_by)}
    end
  end
end
