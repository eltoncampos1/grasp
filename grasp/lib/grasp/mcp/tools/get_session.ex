defmodule Grasp.MCP.Tools.GetSession do
  @moduledoc """
  Read what a review session is showing, as a graph: `cards` with what each one calls and
  is called by, `edges` naming the call each one was opened from, `columns` giving the
  left-to-right layout, and `focus`. The card ids it returns are what `open_card`,
  `close_card`, `focus_card` and `highlight_card` address.

  Every session tool answers in this shape, so the reply to a change is the whole graph
  after it.
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
  end

  @impl true
  def execute(%{session: session}, frame) do
    case Tools.ensure_session(session) do
      {:ok, session} -> Tools.reply(frame, Forest.to_map(Session.get(session)))
      {:error, response} -> Tools.error(frame, response)
    end
  end
end
