defmodule Grasp.MCP.Tools.SetView do
  @moduledoc """
  Show a card as its source or as its diff against the base ref, which is how you point at
  what a pull request did to one function rather than at the function.

  Only a modified function has two sides: asking for the diff of anything else is an error,
  and `source` is always available.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Diff
  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  schema do
    field(:session, :string,
      default: "default",
      description: "The review session to act on; default `default`, which the page at `/` shows"
    )

    field(:card_id, :integer, required: true, description: "Id of the card to swap")

    field(:view, :string,
      required: true,
      enum: ["source", "diff"],
      description: "`source` for the branch's version, `diff` for the change against the base"
    )
  end

  @impl true
  def execute(%{session: session, card_id: card_id, view: asked}, frame) do
    with {:ok, view} <- view(asked),
         {:ok, card} <- Tools.fetch_card(session, card_id),
         :ok <- comparable(view, card.function_id) do
      Tools.reply(frame, Forest.to_map(Session.set_view(session, card_id, view)))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  # The session holds the view as an atom, and a name it has none for is the client's
  # error rather than a card that quietly stays as it was.
  defp view("source"), do: {:ok, :source}
  defp view("diff"), do: {:ok, :diff}
  defp view(other), do: {:error, "unknown view: #{other}"}

  defp comparable(:source, _function_id), do: :ok

  defp comparable(:diff, function_id) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_function(index, function_id) do
      if Diff.diffable?(record), do: :ok, else: {:error, "no diff for #{function_id}"}
    end
  end
end
