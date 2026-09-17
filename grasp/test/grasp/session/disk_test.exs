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
