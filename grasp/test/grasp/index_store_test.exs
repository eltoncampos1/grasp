defmodule Grasp.IndexStoreTest do
  use ExUnit.Case, async: false

  alias Grasp.IndexStore

  @fixture Path.expand("../fixtures/index.json", __DIR__)

  setup do
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)
    :ok
  end

  test "the fixture index is loaded at boot" do
    assert %Grasp.Index{} = index = IndexStore.get()
    assert {:ok, _} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
    assert IndexStore.path() == @fixture
  end

  test "load/1 replaces the index and broadcasts" do
    IndexStore.subscribe()
    path = tmp_copy(fn doc -> put_in(doc, ["project", "app"], "other_app") end)

    assert :ok = IndexStore.load(path)
    assert_receive :index_reloaded
    assert IndexStore.get().project["app"] == "other_app"
  end

  test "load/1 keeps the previous index when the file is unreadable" do
    before = IndexStore.get()
    assert {:error, _} = IndexStore.load(@fixture <> ".missing")
    assert IndexStore.get() == before
  end

  test "reload/0 re-reads the watched path" do
    path = tmp_copy(& &1)
    :ok = IndexStore.load(path)
    IndexStore.subscribe()

    doc = path |> File.read!() |> Jason.decode!() |> put_in(["project", "app"], "reloaded")
    File.write!(path, Jason.encode!(doc))

    assert :ok = IndexStore.reload()
    assert_receive :index_reloaded
    assert IndexStore.get().project["app"] == "reloaded"
  end

  test "a changed mtime triggers a reload" do
    path = tmp_copy(& &1)
    :ok = IndexStore.load(path)
    IndexStore.subscribe()

    doc = path |> File.read!() |> Jason.decode!() |> put_in(["project", "app"], "touched")
    File.write!(path, Jason.encode!(doc))
    future = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> Kernel.+(5)
    File.touch!(path, future)

    send(IndexStore, :poll)
    assert_receive :index_reloaded, 1_000
    assert IndexStore.get().project["app"] == "touched"
  end

  defp tmp_copy(transform) do
    path = Path.join(System.tmp_dir!(), "grasp-store-#{System.unique_integer([:positive])}.json")
    doc = @fixture |> File.read!() |> Jason.decode!() |> transform.()
    File.write!(path, Jason.encode!(doc))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
