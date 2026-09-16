defmodule Grasp.Diff do
  @moduledoc """
  The line diff between the base version of a function and the one on the branch.

  A function's two sources are short and read together, so the diff is per line and
  nothing smaller: `List.myers_difference/2` over the split sources, flattened so each
  entry is one line and the list reads top to bottom, the way the viewer renders it.
  `:del` lines come from the base, `:ins` lines from the current source, and `:eq` lines
  belong to both.

  An empty source has no lines at all rather than one empty line, so a function the base
  did not have reads as every line inserted instead of a spurious deletion of nothing.
  """

  @type op :: :eq | :del | :ins

  @doc """
  The line-by-line diff from `base` to `current`, in reading order.

      iex> Grasp.Diff.lines("a\\nb\\nc", "a\\nx\\nc")
      [eq: "a", del: "b", ins: "x", eq: "c"]
  """
  @spec lines(String.t(), String.t()) :: [{op(), String.t()}]
  def lines(base, current) when is_binary(base) and is_binary(current) do
    base
    |> split()
    |> List.myers_difference(split(current))
    |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)
  end

  @doc """
  How many lines `current` adds to and removes from `base`.

      iex> Grasp.Diff.stats("a\\nb\\nc", "a\\nx\\nc")
      %{added: 1, removed: 1}
  """
  @spec stats(String.t(), String.t()) :: %{added: non_neg_integer(), removed: non_neg_integer()}
  def stats(base, current) do
    Enum.reduce(lines(base, current), %{added: 0, removed: 0}, fn
      {:ins, _line}, stats -> %{stats | added: stats.added + 1}
      {:del, _line}, stats -> %{stats | removed: stats.removed + 1}
      {:eq, _line}, stats -> stats
    end)
  end

  defp split(""), do: []
  defp split(source), do: String.split(source, "\n")
end
