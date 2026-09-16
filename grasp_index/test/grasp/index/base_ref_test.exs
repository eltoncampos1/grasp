defmodule Grasp.Index.BaseRefTest do
  use ExUnit.Case, async: false

  alias Grasp.Index.BaseRef

  setup do
    root = Path.join(System.tmp_dir!(), "grasp-base-ref-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Grasp Test"])
    git!(root, ["config", "user.email", "grasp@example.com"])
    git!(root, ["config", "commit.gpgsign", "false"])

    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :f\nend\n")
    write!(root, "lib/keep.ex", "defmodule Keep do\n  def k, do: :k\nend\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "base"])
    git!(root, ["tag", "base"])

    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :changed\nend\n")
    write!(root, "lib/b.ex", "defmodule B do\n  def g, do: :g\nend\n")
    File.rm!(Path.join(root, "lib/keep.ex"))
    write!(root, "README.md", "# readme\n")

    %{root: root, base_sha: git!(root, ["rev-parse", "base^{commit}"])}
  end

  test "resolves the base commit, the changed sources and their base contents", context do
    assert {:ok, resolved} = BaseRef.resolve(context.root, "base")

    assert resolved.base_ref == "base"
    assert resolved.base_sha == context.base_sha
    assert resolved.files == ["lib/a.ex", "lib/b.ex", "lib/keep.ex"]
    assert resolved.base_sources |> Map.keys() |> Enum.sort() == ["lib/a.ex", "lib/keep.ex"]
    assert resolved.base_sources["lib/a.ex"] == "defmodule A do\n  def f, do: :f\nend\n"
    assert resolved.base_sources["lib/keep.ex"] =~ "def k, do: :k"
  end

  test "keeps only sources under the given paths", context do
    write!(context.root, "test/a_test.exs", "defmodule ATest do\nend\n")

    assert {:ok, resolved} = BaseRef.resolve(context.root, "base", paths: ["lib", "test"])
    assert resolved.files == ["lib/a.ex", "lib/b.ex", "lib/keep.ex", "test/a_test.exs"]
  end

  test "reports a ref no commit answers to", context do
    assert BaseRef.resolve(context.root, "nope") == {:error, "unknown ref: nope"}
  end

  test "reports a directory that is not a repository" do
    assert BaseRef.resolve(System.tmp_dir!(), "main") == {:error, "not a git repository"}
  end

  defp write!(root, path, contents) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
