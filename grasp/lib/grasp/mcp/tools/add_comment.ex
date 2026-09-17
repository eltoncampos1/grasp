defmodule Grasp.MCP.Tools.AddComment do
  @moduledoc """
  Write a review comment on one line of a function, as the agent. The thread appears in the
  reviewer's gutter beside that line, next to the human's own comments, and is kept with the
  project rather than with the canvas — closing the card does not lose it.

  Use it to leave a finding where the code is, rather than in prose the reviewer has to map
  back onto the file: one thread per finding, on the line it is about. The line is numbered
  as `get_function` shows the source, so read the function first and write on a line it
  actually has; a line outside the function is an error naming the range.

  `side` is `new` for the branch's code and `old` for the base version of a function the
  branch modified, which is how a comment lands on a line the branch deleted.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Comments
  alias Grasp.MCP.Comments, as: Shape
  alias Grasp.MCP.Tools

  @sides ~w(new old)

  schema do
    field(:function_id, :string,
      required: true,
      description: "The function to comment on, `Module.fun/arity`"
    )

    field(:line, :integer,
      required: true,
      description:
        "The line to write on, numbered as the source is: the `new` side from the " <>
          "function's first line, the `old` side from 1"
    )

    field(:body, :string, required: true, description: "What the comment says")

    field(:side, :string,
      default: "new",
      description:
        "`new` for the branch's code, `old` for the base version of a modified " <>
          "function; default `new`"
    )
  end

  @impl true
  def execute(%{function_id: function_id, line: line, body: body} = params, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, side} <- side(Map.get(params, :side, "new")),
         {:ok, record} <- Tools.fetch_function(index, function_id),
         :ok <- Shape.check_line(record, side, line),
         {:ok, thread} <- add(record, side, line, body) do
      Tools.reply(frame, Shape.thread_map(thread, index))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp side(side) when side in @sides, do: {:ok, side}
  defp side(side), do: {:error, ~s(side must be "new" or "old", not "#{side}")}

  # The snippet is read off the record now, since it is the text the comment is about and
  # the line it sits on may be edited before anyone reads the thread.
  defp add(record, side, line, body) do
    attrs = %{
      function_id: record["id"],
      side: side,
      line: line,
      body: body,
      author: "agent",
      snippet: Comments.snippet(record, side, line)
    }

    case Comments.add(attrs) do
      {:ok, thread} -> {:ok, thread}
      {:error, :invalid} -> {:error, "body must not be blank"}
    end
  end
end
