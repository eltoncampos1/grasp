defmodule Grasp.GitHub.DiffTest do
  use ExUnit.Case, async: true

  alias Grasp.GitHub.Diff

  test "commentable_lines/1 reads one range per hunk, keyed by the new-side path" do
    assert Diff.commentable_lines(pull_request_diff()) == %{
             "lib/sample_app/greeter.ex" => [1..8],
             "lib/sample_app/formatter.ex" => [10..13]
           }
  end

  test "commentable_lines/1 skips a deleted file" do
    diff = """
    diff --git a/lib/sample_app/legacy.ex b/lib/sample_app/legacy.ex
    deleted file mode 100644
    --- a/lib/sample_app/legacy.ex
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -defmodule SampleApp.Legacy do
    -end
    """

    assert Diff.commentable_lines(diff) == %{}
  end

  test "commentable_lines/1 reads a hunk of one line" do
    assert Diff.commentable_lines(hunk("@@ -3 +5 @@")) == %{"lib/sample_app/greeter.ex" => [5..5]}
  end

  test "commentable_lines/1 keeps the file of a hunk that adds nothing" do
    assert Diff.commentable_lines(hunk("@@ -3,2 +5,0 @@")) == %{"lib/sample_app/greeter.ex" => []}
  end

  test "commentable_lines/1 reads several hunks of one file in order" do
    diff = """
    --- a/lib/sample_app/greeter.ex
    +++ b/lib/sample_app/greeter.ex
    @@ -1,2 +1,3 @@
    +  def greet(name), do: name
    @@ -20,2 +30,4 @@
    +  def shout(name), do: name
    """

    assert Diff.commentable_lines(diff) == %{"lib/sample_app/greeter.ex" => [1..3, 30..33]}
  end

  test "commentable_lines/1 does not read an added line beginning with ++ as a header" do
    diff = """
    --- a/lib/sample_app/counter.ex
    +++ b/lib/sample_app/counter.ex
    @@ -1,2 +1,4 @@
     defmodule SampleApp.Counter do
    +++ extras
    +  def all(list), do: list
     end
    @@ -20 +22,2 @@
    +  def other(list), do: list
     end
    """

    assert Diff.commentable_lines(diff) == %{"lib/sample_app/counter.ex" => [1..4, 22..23]}
  end

  defp hunk(header) do
    """
    --- a/lib/sample_app/greeter.ex
    +++ b/lib/sample_app/greeter.ex
    #{header}
    """
  end

  # The diff `gh pr diff` answers for the sample pull request, as `test/support/fake_gh.sh`
  # writes it.
  defp pull_request_diff do
    """
    diff --git a/lib/sample_app/greeter.ex b/lib/sample_app/greeter.ex
    index 1111111..2222222 100644
    --- a/lib/sample_app/greeter.ex
    +++ b/lib/sample_app/greeter.ex
    @@ -1,6 +1,8 @@
     defmodule SampleApp.Greeter do
       @moduledoc false
       def farewell(name), do: "Bye, " <> name
    +  def greet(name), do: "Hello, " <> name
    +  def shout(name), do: String.upcase(name)
       def plain(name), do: name
       def other(name), do: name
     end
    diff --git a/lib/sample_app/formatter.ex b/lib/sample_app/formatter.ex
    index 3333333..4444444 100644
    --- a/lib/sample_app/formatter.ex
    +++ b/lib/sample_app/formatter.ex
    @@ -10,3 +10,4 @@ defmodule SampleApp.Formatter do
       def shout(text), do: String.upcase(text)
    +  def whisper(text), do: String.downcase(text)
       def plain(text), do: text
     end
    """
  end
end
