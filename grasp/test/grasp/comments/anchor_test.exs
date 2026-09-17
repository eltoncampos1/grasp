defmodule Grasp.Comments.AnchorTest do
  use ExUnit.Case, async: true

  alias Grasp.Comments.Anchor

  @source """
  def run(list) do
    total = Enum.sum(list)
    total * 2
  end\
  """

  setup do
    %{record: %{"source" => @source, "span" => %{"start_line" => 10, "end_line" => 13}}}
  end

  test "a line still carrying its snippet keeps its number", %{record: record} do
    assert Anchor.place(thread(11, "total = Enum.sum(list)"), record) == {:new, 11}
  end

  test "a comment with no snippet trusts its number", %{record: record} do
    assert Anchor.place(thread(12, nil), record) == {:new, 12}
    assert Anchor.place(thread(99, nil), record) == :outdated
  end

  test "a moved line is found by its snippet", %{record: record} do
    assert Anchor.place(thread(12, "total = Enum.sum(list)"), record) == {:new, 11}
  end

  test "an edited line is outdated", %{record: record} do
    assert Anchor.place(thread(11, "total = Enum.count(list)"), record) == :outdated
  end

  test "a snippet on several lines stays on its own line while that line holds" do
    record = %{
      "source" => "def run do\n  :ok\n  :ok\nend",
      "span" => %{"start_line" => 1, "end_line" => 4}
    }

    assert Anchor.place(thread(3, ":ok"), record) == {:new, 3}
    assert Anchor.place(thread(1, ":ok"), record) == :outdated
  end

  test "the old side reads the base source, numbered from one" do
    record = %{
      "source" => "def run, do: :new",
      "base_source" => "def run do\n  :old\nend",
      "span" => %{"start_line" => 40, "end_line" => 40}
    }

    assert Anchor.place(old_thread(2, ":old"), record) == {:old, 2}
    assert Anchor.place(old_thread(3, ":old"), record) == {:old, 2}
    assert Anchor.place(old_thread(2, ":gone"), record) == :outdated
  end

  test "a record with no base source cannot hold an old-side comment", %{record: record} do
    assert Anchor.place(old_thread(1, nil), record) == :outdated
  end

  test "a comment whose function has left the index is an orphan" do
    assert Anchor.place(thread(11, "total = Enum.sum(list)"), nil) == :orphan
    assert Anchor.place(old_thread(1, nil), nil) == :orphan
  end

  defp thread(line, snippet), do: %{side: "new", line: line, snippet: snippet}
  defp old_thread(line, snippet), do: %{side: "old", line: line, snippet: snippet}
end
