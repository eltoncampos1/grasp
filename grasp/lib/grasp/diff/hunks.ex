defmodule Grasp.Diff.Hunks do
  @moduledoc """
  Folds the unchanged stretches of a rendered diff away, the way a pull request shows a
  changed file.

  The input is the per-line list `Grasp.Highlight.diff_lines/2` hands back, each entry
  carrying the `op` the diff gave it. An entry is an *anchor* when it is part of the change
  (`op` is `:ins` or `:del`) or when a comment thread sits on it — a thread names a line, and
  folding the line it hangs from would take the conversation off the card. The `context`
  entries on either side of every anchor stay visible so a change reads against the code
  around it, and each remaining run of unchanged lines collapses into one `t:fold/0` naming
  the current lines it hides.

  A run of exactly one line is left where it is: the row that would hide it is taller than
  the line itself, so folding there costs space instead of saving it. A fold the reader has
  opened — its first line listed in `expanded` — is emitted as its lines again, which is what
  makes expanding cheap: nothing is remembered about the fold beyond the line it starts at.

  Deleted lines are anchors, so every folded run is made of kept lines, each numbered as the
  current file numbers it; a fold's `from` and `to` are read from the `:new`-side entries of
  its run, since an `:old` entry carries a base-commit number the reader cannot click.
  """

  @typedoc """
  A run of unchanged lines shown as one row: the current lines `from` through `to` that it
  stands for, and `count`, how many entries it hides.
  """
  @type fold :: %{fold: true, from: pos_integer(), to: pos_integer(), count: pos_integer()}

  @typedoc """
  `context` is how many lines stay visible on either side of an anchor; `keep` holds the
  `{side, line}` anchors of the card's comment threads; `expanded` holds the `from` line of
  every fold the reader has opened.
  """
  @type opts :: [
          context: non_neg_integer(),
          keep: MapSet.t({:new | :old, pos_integer()}),
          expanded: MapSet.t(pos_integer())
        ]

  @doc """
  The lines of a diff with every unchanged stretch outside the context of a change folded
  into a `t:fold/0`.

  A list with no anchor at all — an unchanged function drawn in diff view, and nobody has
  commented on it — folds whole, into the single fold that stands for all of it.
  """
  @spec fold([Grasp.Highlight.line()], opts()) :: [Grasp.Highlight.line() | fold()]
  def fold(lines, opts \\ []) when is_list(lines) do
    context = Keyword.get(opts, :context, 3)
    keep = Keyword.get(opts, :keep, MapSet.new())
    expanded = Keyword.get(opts, :expanded, MapSet.new())

    visible = visible_indexes(lines, context, keep)

    lines
    |> Enum.with_index()
    |> Enum.chunk_by(fn {_line, index} -> MapSet.member?(visible, index) end)
    |> Enum.flat_map(fn [{_first, index} | _rest] = chunk ->
      entries = Enum.map(chunk, fn {line, _index} -> line end)

      if MapSet.member?(visible, index) or length(entries) == 1 do
        entries
      else
        fold = fold_row(entries)
        if MapSet.member?(expanded, fold.from), do: entries, else: [fold]
      end
    end)
  end

  defp visible_indexes(lines, context, keep) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {line, index}, acc ->
      if anchor?(line, keep) do
        index
        |> around(context, length(lines))
        |> Enum.into(acc)
      else
        acc
      end
    end)
  end

  defp anchor?(line, keep),
    do: line.op != :eq or MapSet.member?(keep, {line.side, line.line})

  defp around(index, context, count),
    do: max(index - context, 0)..min(index + context, count - 1)//1

  defp fold_row(entries) do
    numbers = for %{side: :new, line: line} <- entries, do: line

    %{
      fold: true,
      from: List.first(numbers),
      to: List.last(numbers),
      count: length(entries)
    }
  end
end
