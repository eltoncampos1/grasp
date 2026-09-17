defmodule Grasp.GitHub.Diff do
  @moduledoc """
  Which lines of a pull request can carry a review comment.

  GitHub accepts a line comment only on a line the pull request's own diff covers: a line
  outside every hunk is rejected with a validation error that says nothing useful about
  why. Reading the hunk headers first turns that into an answer the viewer can give before
  posting — this thread's line is not in the diff, so it goes on the file instead.

  Only the new side matters. A comment is written against the head commit, so the range a
  hunk contributes is its `+c,d` half, and a section whose new side is `/dev/null` — a
  deleted file — carries no commentable line at all. A file that appears in the diff with
  no usable hunk keeps its key with an empty list, so a caller can tell a file the pull
  request does not touch from one it touches without adding a line.
  """

  @hunk ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  @doc """
  The new-side line ranges of `diff`, one range per hunk, keyed by file path.

  `diff` is a unified diff as `git diff` or `gh pr diff` writes it.
  """
  @spec commentable_lines(String.t()) :: %{String.t() => [Range.t()]}
  def commentable_lines(diff) when is_binary(diff) do
    {_previous, _path, files} =
      diff
      |> String.split("\n")
      |> Enum.reduce({"", nil, %{}}, fn line, {previous, path, files} ->
        cond do
          new_side_header?(previous, line) ->
            {path, files} = open_section(line, files)
            {line, path, files}

          is_nil(path) ->
            {line, path, files}

          true ->
            {line, path, hunk(line, path, files)}
        end
      end)

    Map.new(files, fn {path, ranges} -> {path, Enum.reverse(ranges)} end)
  end

  # An added line whose own text begins with `++ ` is written `+++ ` in the diff, so the
  # four characters alone do not make a header: the old-side half has to precede it.
  defp new_side_header?(previous, line),
    do: String.starts_with?(line, "+++ ") and String.starts_with?(previous, "--- ")

  defp open_section(line, files) do
    header = line |> String.replace_prefix("+++ ", "") |> String.trim()

    case String.replace_prefix(header, "b/", "") do
      "/dev/null" -> {nil, files}
      path -> {path, Map.put_new(files, path, [])}
    end
  end

  defp hunk(line, path, files) do
    case Regex.run(@hunk, line, capture: :all_but_first) do
      nil -> files
      [start] -> add_range(files, path, String.to_integer(start), 1)
      [start, count] -> add_range(files, path, String.to_integer(start), String.to_integer(count))
    end
  end

  # A hunk that adds nothing to the new side — `+c,0`, a pure deletion — covers no line.
  defp add_range(files, _path, _start, 0), do: files

  defp add_range(files, path, start, count) do
    range = start..(start + count - 1)
    Map.update(files, path, [range], &[range | &1])
  end
end
