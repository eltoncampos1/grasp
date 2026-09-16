defmodule Grasp.DiffTest do
  use ExUnit.Case, async: true

  alias Grasp.Diff

  doctest Grasp.Diff

  test "lines/2 is one entry per line, in reading order" do
    assert Diff.lines("a\nb\nc", "a\nx\nc") == [eq: "a", del: "b", ins: "x", eq: "c"]
  end

  test "lines/2 on identical sources is all eq" do
    assert Diff.lines("a\nb", "a\nb") == [eq: "a", eq: "b"]
  end

  test "an empty base is every line inserted" do
    assert Diff.lines("", "a\nb") == [ins: "a", ins: "b"]
    assert Diff.lines("", "") == []
  end

  test "an empty current is every line deleted" do
    assert Diff.lines("a\nb", "") == [del: "a", del: "b"]
  end

  test "a blank line is a line" do
    assert Diff.lines("a\n\nb", "a\nb") == [eq: "a", del: "", eq: "b"]
  end

  test "stats/2 counts the inserted and deleted lines" do
    assert Diff.stats("a\nb\nc", "a\nx\nc") == %{added: 1, removed: 1}
    assert Diff.stats("a\nb", "a\nb") == %{added: 0, removed: 0}
    assert Diff.stats("a", "a\nb\nc") == %{added: 2, removed: 0}
    assert Diff.stats("a\nb\nc", "a") == %{added: 0, removed: 2}
  end
end
