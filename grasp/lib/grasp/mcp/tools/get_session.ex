defmodule Grasp.MCP.Tools.GetSession do
  @moduledoc """
  Read what a review session is showing: every open card, which of them are roots, what
  each was opened from, what it points at, and which card has focus. The card ids it
  returns are what `open_card`, `close_card`, `focus_card` and `highlight_card` address.
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
  end

  @impl true
  def execute(%{session: session}, frame) do
    :ok = Session.ensure(session)
    Tools.reply(frame, Forest.to_map(Session.get(session)))
  end
end
