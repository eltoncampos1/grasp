defmodule Grasp.Diff.HunksTest do
  use ExUnit.Case, async: true

  alias Grasp.Diff.Hunks

  defp line(number, op \\ :eq, side \\ :new),
    do: %{side: side, line: number, op: op, html: "<span>#{number}</span>"}

  # Twenty lines of the current file, one of which the branch inserted.
  defp twenty(changed_at),
    do: for(number <- 1..20, do: line(number, if(number == changed_at, do: :ins, else: :eq)))

  # What a row stands for: a fold as its span, a line as its number.
  defp shape(%{fold: true} = fold), do: {:fold, fold.from, fold.to, fold.count}
  defp shape(line), do: line.line

  defp shapes(rows), do: Enum.map(rows, &shape/1)

  describe "fold/2" do
    test "one change in a long function keeps three lines around it and folds the rest" do
      assert shapes(Hunks.fold(twenty(10))) ==
               [{:fold, 1, 6, 6}, 7, 8, 9, 10, 11, 12, 13, {:fold, 14, 20, 7}]
    end

    test "two changes closer than twice the context share it, with no fold between" do
      lines = for number <- 1..20, do: line(number, if(number in [8, 12], do: :ins, else: :eq))

      assert shapes(Hunks.fold(lines)) ==
               [{:fold, 1, 4, 4}] ++ Enum.to_list(5..15) ++ [{:fold, 16, 20, 5}]
    end

    test "a single unchanged line between two contexts is drawn rather than folded" do
      lines = for number <- 1..20, do: line(number, if(number in [6, 14], do: :ins, else: :eq))

      assert shapes(Hunks.fold(lines)) ==
               [{:fold, 1, 2, 2}] ++ Enum.to_list(3..17) ++ [{:fold, 18, 20, 3}]
    end

    test "a line a comment sits on is an anchor and takes its own context with it" do
      folded = Hunks.fold(twenty(10), keep: MapSet.new([{:new, 18}]))

      assert shapes(folded) == [{:fold, 1, 6, 6}] ++ Enum.to_list(7..20)
    end

    test "a fold the reader opened is drawn as its lines" do
      folded = Hunks.fold(twenty(10), expanded: MapSet.new([1]))

      assert shapes(folded) == Enum.to_list(1..13) ++ [{:fold, 14, 20, 7}]
    end

    test "a diff with nothing changed and nothing commented folds whole" do
      assert shapes(Hunks.fold(Enum.map(1..20, &line/1))) == [{:fold, 1, 20, 20}]
    end

    test "a lone line with no anchor stays, since a fold row would be taller than it" do
      assert Hunks.fold([line(1)]) == [line(1)]
    end

    test "deleted lines are anchors and never number a fold" do
      lines =
        Enum.map(1..3, &line/1) ++
          [line(7, :del, :old), line(4, :ins)] ++ Enum.map(5..20, &line/1)

      folded = Hunks.fold(lines, context: 1)

      assert shapes(folded) == [{:fold, 1, 2, 2}, 3, 7, 4, 5, {:fold, 6, 20, 15}]
      assert Enum.at(folded, 2).side == :old
    end

    test "the width of the context is the caller's" do
      assert shapes(Hunks.fold(twenty(10), context: 1)) ==
               [{:fold, 1, 8, 8}, 9, 10, 11, {:fold, 12, 20, 9}]
    end

    test "an empty list folds to nothing" do
      assert Hunks.fold([]) == []
    end
  end
end
