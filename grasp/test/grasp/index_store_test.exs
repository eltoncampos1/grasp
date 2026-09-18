defmodule Grasp.IndexStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    log = capture_log(fn -> assert {:error, _} = IndexStore.load(@fixture <> ".missing") end)

    assert log =~ "could not load index"
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

  test "a failed load is remembered, reported once and not retried until the file changes" do
    path = tmp_copy(&Map.put(&1, "version", 2))
    IndexStore.subscribe()

    log =
      capture_log(fn -> assert {:error, {:unsupported_document, 2}} = IndexStore.load(path) end)

    assert log =~ "could not load index"
    assert IndexStore.last_error() == {:unsupported_document, 2}
    refute_receive :index_reloaded

    send(IndexStore, :poll)
    send(IndexStore, :poll)
    assert IndexStore.path() == path
    refute_receive :index_reloaded

    assert :ok = IndexStore.load(@fixture)
    assert IndexStore.last_error() == nil
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

  test "load/1 clears the highlight parse cache" do
    :ok = Grasp.Highlight.ensure_cache()

    {:ok, index} = Grasp.Index.load(@fixture)
    {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")
    Grasp.Highlight.render(record, card_id: 1, open_calls: %{}, external?: fn _ -> false end)
    assert :ets.info(:grasp_highlight_cache, :size) > 0

    assert :ok = IndexStore.load(@fixture)
    assert :ets.info(:grasp_highlight_cache, :size) == 0
  end

  test "a project with no index yet starts empty and watches where the file will be written" do
    path = Path.join(System.tmp_dir!(), "grasp-absent-#{System.unique_integer([:positive])}.json")

    assert {:ok, state} = IndexStore.init(path: path)
    assert state.path == path
    assert state.mtime == nil
    assert state.last_error == nil
    assert IndexStore.get() == nil
  end

  @tag :tmp_dir
  test "the watched path defaults to the index the build task writes under the project root",
       %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:grasp, :index_path)
    Application.put_env(:grasp, :index_path, nil)
    on_exit(fn -> Application.put_env(:grasp, :index_path, previous) end)

    # A directory of its own, so the assertion does not turn on whether the repository
    # happens to hold an index of itself.
    {:ok, state} = File.cd!(tmp_dir, fn -> IndexStore.init([]) end)

    assert state.path == Path.join(tmp_dir, ".grasp/index.json")
    assert state.mtime == nil
    assert state.last_error == nil
    assert IndexStore.get() == nil
  end

  defp tmp_copy(transform) do
    path = Path.join(System.tmp_dir!(), "grasp-store-#{System.unique_integer([:positive])}.json")
    doc = @fixture |> File.read!() |> Jason.decode!() |> transform.()
    File.write!(path, Jason.encode!(doc))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
