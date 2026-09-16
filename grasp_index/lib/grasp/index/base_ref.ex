defmodule Grasp.Index.BaseRef do
  @moduledoc """
  Resolves a git ref into the commit an index is compared against, the source files that
  differ from it, and the contents those files had at that commit.

  The base commit is `git merge-base REF HEAD`, so a branch whose target has moved on is
  compared against the point the two diverged rather than against work the branch never
  saw. A ref with no common history has no merge base, and the ref's own commit is used
  instead.

  The file list is the union of the tracked paths that differ from the base commit and
  the files git reports as untracked, narrowed to `.ex` and `.exs` sources under the
  project's compile paths. A deleted file stays in the list: its functions still have to
  be reported as removed. Paths are asked for, and resolved, relative to the working
  directory rather than the repository root, so a Mix project sitting in a subdirectory
  of a larger repository sees the project-relative paths the index itself uses.

  Everything goes through `git` as an external command, and every failure comes back as
  an error string a caller can print: a directory outside a repository, a ref no commit
  answers to, or no `git` on the machine at all.
  """

  @type resolved :: %{
          base_ref: String.t(),
          base_sha: String.t(),
          files: [String.t()],
          base_sources: %{String.t() => String.t()}
        }

  @doc """
  Resolves `ref` against the repository holding `root`.

  `:paths` lists the directories whose sources are of interest, defaulting to `["lib"]`;
  a file outside them is left out of both `:files` and `:base_sources`.
  """
  @spec resolve(String.t(), String.t(), paths: [String.t()]) ::
          {:ok, resolved()} | {:error, String.t()}
  def resolve(root, ref, opts \\ []) do
    paths = Keyword.get(opts, :paths, ["lib"])

    with {:ok, _} <- git(["rev-parse", "--git-dir"], root, "not a git repository"),
         {:ok, base_sha} <- base_sha(root, ref) do
      files = changed_files(root, base_sha, paths)

      {:ok,
       %{
         base_ref: ref,
         base_sha: base_sha,
         files: files,
         base_sources: base_sources(root, base_sha, files)
       }}
    end
  end

  defp base_sha(root, ref) do
    case git(["merge-base", ref, "HEAD"], root, "unknown ref: #{ref}") do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _} -> disjoint_history_sha(root, ref)
    end
  end

  # No merge base means the ref shares no history with HEAD (a grafted branch, a shallow
  # clone); the ref's own commit is the only base there is.
  defp disjoint_history_sha(root, ref) do
    case git(["rev-parse", "--verify", ref <> "^{commit}"], root, "unknown ref: #{ref}") do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, message} -> {:error, message}
    end
  end

  defp changed_files(root, base_sha, paths) do
    prefixes = Enum.map(paths, &(String.trim_trailing(&1, "/") <> "/"))

    changed = lines(git(["diff", "--name-only", "--relative", base_sha], root, ""))
    untracked = lines(git(["ls-files", "--others", "--exclude-standard"], root, ""))

    (changed ++ untracked)
    |> Enum.filter(&source?(&1, prefixes))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source?(path, prefixes),
    do: Path.extname(path) in [".ex", ".exs"] and String.starts_with?(path, prefixes)

  defp base_sources(root, base_sha, files) do
    for file <- files,
        {:ok, source} <- [git(["show", "#{base_sha}:./#{file}"], root, "")],
        into: %{},
        do: {file, source}
  end

  defp lines({:ok, output}), do: output |> String.split("\n", trim: true)
  defp lines({:error, _}), do: []

  defp git(args, root, message) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, message}
    end
  rescue
    ErlangError -> {:error, "git is not installed"}
  end
end
