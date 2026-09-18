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

  # The agent's shell runs inside the tree under review and cannot change directory, so the
  # root it works on has to be nameable. The refusal answers before any command runs, which
  # is what makes it the cheap proof that the switch reaches `Grasp.PullRequest.open/2`.
  test "the task works on the root it is given" do
    worktree = Path.join(File.cwd!(), ".grasp/worktrees/pr-1")

    assert_raise Mix.Error, ~r/is a worktree Grasp opened a pull request in/, fn ->
      Mix.Tasks.Grasp.Pr.run(["--root", worktree, "7"])
    end
  end
end
