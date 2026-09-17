defmodule Grasp.Session.DiskTest do
  # The sessions directory is application-wide state this module replaces, so it runs alone.
  use ExUnit.Case, async: false

  alias Grasp.Session.Disk
  alias Grasp.Session.Forest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:grasp, :sessions_dir)
    Application.put_env(:grasp, :sessions_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:grasp, :sessions_dir, previous) end)

    %{name: "disk-#{System.unique_integer([:positive])}"}
  end

  test "reading a session that was never written is empty", %{name: name} do
    assert Disk.read(name, nil) == :empty
  end

  test "a written session reads back as the forest that was written", %{name: name} do
    {forest, greeter} = Forest.open_root(Forest.new(), "SampleApp.Greeter.greet/2")
    {forest, _wrap} = Forest.open_child(forest, greeter, "SampleApp.Formatter.wrap/1")

    assert Disk.write(name, forest) == :ok
    assert Disk.read(name, nil) == {:ok, forest}
  end

  test "a file that is not a session is kept aside and reported", %{name: name, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, name <> ".json")
    File.write!(path, "not json")

    assert {:error, {:corrupt, kept}} = Disk.read(name, nil)
    assert kept == path <> ".corrupt"
    assert File.read!(kept) == "not json"
    refute File.exists?(path)
  end

  test "a file that could not be moved aside is reported as still there", %{
    name: name,
    tmp_dir: tmp_dir
  } do
    locked = Path.join(tmp_dir, "locked")
    File.mkdir_p!(locked)
    path = Path.join(locked, name <> ".json")
    File.write!(path, "not json")
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod!(locked, 0o700) end)
    Application.put_env(:grasp, :sessions_dir, locked)

    assert Disk.read(name, nil) == {:error, {:corrupt, path, :not_moved}}
    assert File.read!(path) == "not json"
  end

  test "a name that is not a session name reaches no file", %{tmp_dir: tmp_dir} do
    outside = Path.join(tmp_dir, "outside.json")

    assert Disk.path("../outside") == nil
    assert Disk.write("../outside", Forest.new()) == :ok
    assert Disk.read("../outside", nil) == :empty
    assert Disk.delete("../outside") == :ok

    refute File.exists?(outside)
    assert File.ls!(tmp_dir) == []
    assert Disk.saved() == []
  end

  test "saved/0 names the written sessions, sorted", %{name: name} do
    assert Disk.write("zeta-" <> name, Forest.new()) == :ok
    assert Disk.write("alpha-" <> name, Forest.new()) == :ok

    assert Disk.saved() == ["alpha-" <> name, "zeta-" <> name]
  end

  test "delete/1 removes the file", %{name: name} do
    assert Disk.write(name, Forest.new()) == :ok
    assert Disk.delete(name) == :ok

    assert Disk.saved() == []
    assert Disk.read(name, nil) == :empty
  end

  test "a name is letters, digits, - and _, up to 40 of them" do
    assert Disk.valid_name?("review-1")
    assert Disk.valid_name?(String.duplicate("a", 40))
    refute Disk.valid_name?("../x")
    refute Disk.valid_name?("")
    refute Disk.valid_name?(String.duplicate("a", 41))
  end
end
