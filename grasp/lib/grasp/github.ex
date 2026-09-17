defmodule Grasp.GitHub do
  @moduledoc """
  The one door to the `gh` command line.

  Publishing a review to GitHub needs a pull request, its diff and a way to post review
  comments on it. All three arrive through `gh`, and they arrive that way on purpose:
  `gh` already holds the reviewer's credentials and already knows which repository the
  checkout belongs to, so the viewer never handles a token and never has to work out an
  owner and a repository name of its own. Endpoints are written with `gh`'s own
  `{owner}/{repo}` placeholders, which it fills from the checkout `root` names.

  Every call is a `System.cmd/3` from that root with stderr folded into stdout, so a
  failure answers with the message a reviewer would have seen in their own terminal. A
  missing `gh` is an ordinary error rather than a raise: it is the first thing a reviewer
  who has never installed it will hit, and a message beats a crash report. The executable
  is the `:grasp, :gh_command` setting, which tests point at a stand-in.
  """

  @typedoc "A pull request as `gh pr view` describes it."
  @type pull_request :: %{
          number: pos_integer(),
          url: String.t(),
          head_sha: String.t(),
          base_ref: String.t()
        }

  @typedoc "A posted review comment: GitHub's id for it and the URL it reads at."
  @type posted :: %{id: pos_integer(), url: String.t()}

  @fields "number,url,headRefOid,baseRefName"

  @doc """
  Runs `gh` with `args` from `root`, answering its output or the output of its failure.

  The output is handed back as `gh` wrote it, trailing newline and all, so a caller that
  wants a diff gets the diff; a failure's output is trimmed, because it is a message. A
  failure that said nothing at all is reported by its exit status, so the error is never
  an empty string the caller would have to explain away.
  """
  @spec run([String.t()], Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, root) when is_list(args) and is_binary(root) do
    command = Application.get_env(:grasp, :gh_command, "gh")

    if System.find_executable(command) do
      case System.cmd(command, args, cd: root, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, failure(output, status)}
      end
    else
      {:error, "gh is not installed or not on PATH"}
    end
  end

  @doc """
  The pull request `number`, or the one the checkout's current branch is open on when
  `number` is nil.
  """
  @spec pull_request(Path.t(), pos_integer() | nil) ::
          {:ok, pull_request()} | {:error, String.t()}
  def pull_request(root, number)
      when is_nil(number) or (is_integer(number) and number > 0) do
    selector = if number, do: [Integer.to_string(number)], else: []

    with {:ok, output} <- run(["pr", "view"] ++ selector ++ ["--json", @fields], root) do
      decode_pull_request(output)
    end
  end

  @doc "The unified diff of pull request `number`."
  @spec diff(Path.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(root, number) when is_integer(number) and number > 0,
    do: run(["pr", "diff", Integer.to_string(number)], root)

  @doc """
  Posts a review comment on pull request `number`.

  The comment names its `body`, the `path` it hangs off, the `commit_id` it is written
  against, and a `kind`: a `:line` comment sits on the new side at `line`, and a `:file`
  comment sits on the file as a whole and carries no line. A `:line` comment with no line,
  and any other kind, is an error rather than a raise, so a caller that built the comment
  from a thread reads about it the same way it reads about a rejection. GitHub rejects a
  line the pull request's diff does not touch, which is what `Grasp.GitHub.Diff` is for.
  """
  @spec create_review_comment(Path.t(), pos_integer(), map()) ::
          {:ok, posted()} | {:error, String.t()}
  def create_review_comment(
        root,
        number,
        %{body: body, path: path, commit_id: commit_id, kind: kind} = comment
      )
      when is_integer(number) and number > 0 do
    args = [
      "api",
      "--method",
      "POST",
      "repos/{owner}/{repo}/pulls/#{number}/comments",
      "-f",
      "body=#{body}",
      "-f",
      "path=#{path}",
      "-f",
      "commit_id=#{commit_id}"
    ]

    with {:ok, placement} <- placement(kind, Map.get(comment, :line)),
         {:ok, output} <- run(args ++ placement, root) do
      decode_posted(output)
    end
  end

  @doc "Posts `body` as a reply to review comment `comment_id` on pull request `number`."
  @spec reply_review_comment(Path.t(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, posted()} | {:error, String.t()}
  def reply_review_comment(root, number, comment_id, body)
      when is_integer(number) and number > 0 and is_integer(comment_id) and comment_id > 0 and
             is_binary(body) do
    args = [
      "api",
      "--method",
      "POST",
      "repos/{owner}/{repo}/pulls/#{number}/comments/#{comment_id}/replies",
      "-f",
      "body=#{body}"
    ]

    with {:ok, output} <- run(args, root), do: decode_posted(output)
  end

  # `-F` sends the line as a JSON number; GitHub rejects the string `-f` would send.
  defp placement(:line, line) when is_integer(line) and line > 0,
    do: {:ok, ["-F", "line=#{line}", "-f", "side=RIGHT"]}

  defp placement(:line, _line), do: {:error, "a line comment needs a line"}

  defp placement(:file, _line), do: {:ok, ["-f", "subject_type=file"]}

  defp placement(kind, _line), do: {:error, "unknown comment kind: #{inspect(kind)}"}

  defp failure(output, status) do
    case String.trim(output) do
      "" -> "gh exited with status #{status}"
      message -> message
    end
  end

  defp decode_pull_request(output) do
    case Jason.decode(output) do
      {:ok,
       %{
         "number" => number,
         "url" => url,
         "headRefOid" => head_sha,
         "baseRefName" => base_ref
       }}
      when is_integer(number) and is_binary(url) and is_binary(head_sha) and is_binary(base_ref) ->
        {:ok, %{number: number, url: url, head_sha: head_sha, base_ref: base_ref}}

      _unexpected ->
        {:error, "unexpected answer from gh pr view: #{String.trim(output)}"}
    end
  end

  defp decode_posted(output) do
    case Jason.decode(output) do
      {:ok, %{"id" => id, "html_url" => url}} when is_integer(id) and is_binary(url) ->
        {:ok, %{id: id, url: url}}

      _unexpected ->
        {:error, "unexpected answer from gh api: #{String.trim(output)}"}
    end
  end
end
