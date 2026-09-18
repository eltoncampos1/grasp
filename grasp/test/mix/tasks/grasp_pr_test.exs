defmodule Mix.Tasks.Grasp.PrTest do
  use ExUnit.Case, async: true

  # What the task does once it has a number is `Grasp.PullRequest`'s, and tested there
  # against temporary repositories; what is the task's own is the argument it is given.
  test "the task takes one pull request number and the switches it knows" do
    assert_raise Mix.Error, ~r/expected one pull request number/, fn ->
      Mix.Tasks.Grasp.Pr.run([])
    end

    assert_raise Mix.Error, ~r/expected one pull request number/, fn ->
      Mix.Tasks.Grasp.Pr.run(["7", "8"])
    end

    assert_raise Mix.Error, ~r/main is not a pull request number/, fn ->
      Mix.Tasks.Grasp.Pr.run(["main"])
    end

    assert_raise Mix.Error, ~r/unknown options/, fn ->
      Mix.Tasks.Grasp.Pr.run(["--branch", "feature", "7"])
    end
  end
end
