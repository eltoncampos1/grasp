defmodule Grasp.MCP.Tools.ReplyComment do
  @moduledoc """
  Answer a review comment, as the agent. The reply joins the thread under the reviewer's
  own, on the line the thread hangs off, and the whole thread comes back.

  Use it to answer what a comment asked — what the code does, what was changed, why a
  suggestion does not hold — so the exchange stays on the line it is about instead of
  scattering across the chat. A thread that is answered and needs nothing further is then
  closed with `resolve_comment`.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Comments
  alias Grasp.MCP.Comments, as: Shape
  alias Grasp.MCP.Tools

  schema do
    field(:comment_id, :integer,
      required: true,
      description: "Id of the thread to answer, as `list_comments` reports it"
    )

    field(:body, :string, required: true, description: "What the reply says")
  end

  @impl true
  def execute(%{comment_id: id, body: body}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, thread} <- reply(id, body) do
      Tools.reply(frame, Shape.thread_map(thread, index))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp reply(id, body) do
    case Comments.reply(id, %{body: body, author: "agent"}) do
      {:ok, thread} -> {:ok, thread}
      {:error, :unknown} -> {:error, "unknown comment: #{id}"}
      {:error, :invalid} -> {:error, "body must not be blank"}
    end
  end
end
