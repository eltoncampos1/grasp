defmodule Grasp.GitHubTest do
  # The missing-gh test swaps the :gh_command setting the whole application reads.
  use ExUnit.Case, async: false

  alias Grasp.GitHub

  setup do
    %{root: File.cwd!()}
  end

  test "pull_request/2 reads the current branch's pull request", %{root: root} do
    assert {:ok, pull_request} = GitHub.pull_request(root, nil)

    assert pull_request == %{
             number: 42,
             url: "https://github.com/acme/sample_app/pull/42",
             head_sha: "0000000",
             base_ref: "main"
           }
  end

  test "pull_request/2 reads a pull request by number", %{root: root} do
    assert {:ok, %{number: 99, head_sha: "9999999"}} = GitHub.pull_request(root, 99)
  end

  test "pull_request/2 answers gh's own message when there is no pull request", %{root: root} do
    assert {:error, message} = GitHub.pull_request(root, 404)
    assert message =~ "no pull requests"
  end

  test "diff/2 answers the unified diff", %{root: root} do
    assert {:ok, diff} = GitHub.diff(root, 42)
    assert diff =~ "+++ b/lib/sample_app/greeter.ex"
    assert diff =~ "@@ -1,6 +1,8 @@"
  end

  test "create_review_comment/3 posts a line comment", %{root: root} do
    assert {:ok, %{id: id, url: url}} =
             GitHub.create_review_comment(root, 42, %{
               body: "this guard is unreachable",
               path: "lib/sample_app/greeter.ex",
               commit_id: "0000000",
               kind: :line,
               line: 3
             })

    assert is_integer(id)
    assert url =~ "https://github.com/acme/sample_app/pull/42#discussion_r"
  end

  test "create_review_comment/3 answers GitHub's validation error", %{root: root} do
    assert {:error, message} =
             GitHub.create_review_comment(root, 42, %{
               body: "GHFAIL",
               path: "lib/sample_app/greeter.ex",
               commit_id: "0000000",
               kind: :file,
               line: nil
             })

    assert message =~ "422"
  end

  test "create_review_comment/3 refuses a line comment with no line", %{root: root} do
    assert GitHub.create_review_comment(root, 42, %{
             body: "this guard is unreachable",
             path: "lib/sample_app/greeter.ex",
             commit_id: "0000000",
             kind: :line,
             line: nil
           }) == {:error, "a line comment needs a line"}
  end

  test "create_review_comment/3 refuses a kind it does not know", %{root: root} do
    assert GitHub.create_review_comment(root, 42, %{
             body: "neither a line nor a file",
             path: "lib/sample_app/greeter.ex",
             commit_id: "0000000",
             kind: :suggestion,
             line: 6
           }) == {:error, "unknown comment kind: :suggestion"}
  end

  test "reply_review_comment/4 posts a reply", %{root: root} do
    assert {:ok, %{id: id, url: url}} = GitHub.reply_review_comment(root, 42, 7, "agreed")
    assert is_integer(id)
    assert url =~ "#discussion_r"
  end

  test "a failure that said nothing is reported by its exit status" do
    assert {:error, message} = GitHub.run(["pr", "view"], "/no/such/directory")
    assert message =~ "gh exited with status"
  end

  test "a gh that is not on PATH is an error, not a crash", %{root: root} do
    command = Application.get_env(:grasp, :gh_command)
    Application.put_env(:grasp, :gh_command, "gh-that-is-not-installed")
    on_exit(fn -> Application.put_env(:grasp, :gh_command, command) end)

    assert GitHub.run(["pr", "view"], root) == {:error, "gh is not installed or not on PATH"}
  end
end
