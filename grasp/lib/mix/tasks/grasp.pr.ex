defmodule Mix.Tasks.Grasp.Pr do
  @shortdoc "Opens a pull request for review in a worktree of its own"

  @moduledoc """
  Puts a pull request's code in a worktree and indexes it against its base branch.

      mix grasp.pr N [--close] [--base REF]

  The working tree this is run from is left alone: the pull request's head is checked out
  under `.grasp/worktrees/pr-N`, `deps/` and a copy of `_build/dev` are lent to it, and the
  index is built inside it and written to the file the viewer watches — `.grasp/index.json`
  here, or whatever `:grasp, :index_path` names. Run it from the project you started Grasp
  in; a worktree it opened earlier is refused. The viewer reloads it within a second or two and the cards read the pull
  request's code, from the worktree.

  Review comments and saved sessions are not in the worktree; they stay under the
  directory the dev server was started in, so they survive `--close`.

  `gh` has to be installed and signed in, and `origin` has to be the remote the pull
  request is on.

  ## Options

    * `--close` - remove the worktree the pull request was opened in and prune the list.
      The removal is forced, so anything left uncommitted in that worktree — an edit the
      agent made on a review comment, say — goes with it. Commit or copy it first.
    * `--base` - review against this ref instead of the branch the pull request targets.
  """

  use Mix.Task

  alias Grasp.PullRequest

  @switches [close: :boolean, base: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.pr: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    number = number(positional)
    run_opts = [log: fn step -> Mix.shell().info(step) end] ++ base(opts[:base])

    if opts[:close], do: close(number, run_opts), else: open(number, run_opts)
  end

  defp open(number, opts) do
    case PullRequest.open(number, opts) do
      {:ok, pull_request} ->
        Mix.shell().info(
          "Pull request #{number} is ready: #{pull_request.title} " <>
            "(#{pull_request.head} against #{pull_request.base}) — #{pull_request.url}"
        )

      {:error, message} ->
        Mix.raise("grasp.pr: #{message}")
    end
  end

  defp close(number, opts) do
    case PullRequest.close(number, opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise("grasp.pr: #{message}")
    end
  end

  defp number([argument]) do
    case Integer.parse(argument) do
      {number, ""} when number > 0 -> number
      _not_a_number -> Mix.raise("grasp.pr: #{argument} is not a pull request number")
    end
  end

  defp number(_arguments), do: Mix.raise("grasp.pr: expected one pull request number")

  defp base(nil), do: []
  defp base(ref), do: [base_override: ref]
end
