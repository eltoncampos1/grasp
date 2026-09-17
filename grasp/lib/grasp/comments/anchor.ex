defmodule Grasp.Comments.Anchor do
  @moduledoc """
  Places a comment on a line of the function record the viewer is about to draw.

  A comment records the line number it was written on and the text of that line. Line
  numbers alone do not survive an edit: inserting a clause above a function moves every
  line of it, and the comment would point at code its author never read. The recorded
  text is the stronger anchor, so placement trusts the number only while the text still
  agrees with it, and otherwise looks for the one line that carries the text.

  Ambiguity resolves towards silence rather than towards a guess. Text appearing on
  several lines places nothing unless the original line still carries it, and a line that
  has been edited out of the function is reported as `:outdated` — the comment is kept and
  shown apart from the code, never re-attached to a line that merely looks similar.

  The `"new"` side reads `record["source"]`, numbered from the span's first line, which is
  the numbering the cards show; the `"old"` side reads `record["base_source"]`, numbered
  from 1, which is the numbering of the diff's base column. A record with no base source
  cannot hold an old-side comment, and a comment whose function has left the index has no
  record at all.
  """

  @type placement :: {:new, pos_integer()} | {:old, pos_integer()} | :outdated | :orphan

  @doc """
  Where `thread` belongs on `record`.

  `{:new, line}` or `{:old, line}` is the line to draw it under, `:outdated` means the
  line it was written on is no longer there, and `:orphan` that the function itself is
  gone (`record` is nil).
  """
  @spec place(Grasp.Comments.thread(), map() | nil) :: placement()
  def place(thread, record) do
    case lines(record, thread.side) do
      nil when is_nil(record) -> :orphan
      nil -> :outdated
      lines -> locate(lines, thread)
    end
  end

  @doc false
  @spec lines(map() | nil, Grasp.Comments.side()) :: [{pos_integer(), String.t()}] | nil
  def lines(nil, _side), do: nil
  def lines(record, "new") when is_map(record), do: number(record["source"], start_line(record))
  def lines(record, "old") when is_map(record), do: number(record["base_source"], 1)
  def lines(_record, _side), do: nil

  defp locate(lines, thread) do
    side = tag(thread.side)

    own =
      Enum.find_value(lines, fn {number, text} -> number == thread.line && String.trim(text) end)

    snippet = thread.snippet

    cond do
      own != nil and (is_nil(snippet) or own == snippet) ->
        {side, thread.line}

      is_binary(snippet) and snippet != "" ->
        case Enum.filter(lines, fn {_number, text} -> String.trim(text) == snippet end) do
          [{number, _text}] -> {side, number}
          _ambiguous_or_absent -> :outdated
        end

      true ->
        :outdated
    end
  end

  defp tag("new"), do: :new
  defp tag("old"), do: :old

  defp number(source, start) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(start)
    |> Enum.map(fn {text, number} -> {number, text} end)
  end

  defp number(_source, _start), do: nil

  defp start_line(record) do
    case record["span"] do
      %{"start_line" => line} when is_integer(line) and line > 0 -> line
      _ -> 1
    end
  end
end
