defmodule GraspWeb.IndexReloadTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, Session}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @shout "SampleApp.Formatter.shout/1"

  setup do
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)
    :ok
  end

  test "a card whose function leaves the index becomes a stub and comes back", %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    Session.open_root(name, @shout)
    assert has_element?(view, "#card-1[data-function-id='#{@shout}']:not(.stub)")

    :ok = IndexStore.load(without_shout())

    assert has_element?(
             view,
             "#card-1.stub .stub__text",
             "No longer in the index — renamed or removed since it was written."
           )

    refute has_element?(view, "#card-1 .stub__docs")

    :ok = IndexStore.load(@fixture)
    assert has_element?(view, "#card-1[data-function-id='#{@shout}']:not(.stub)")
  end

  defp without_shout do
    path = Path.join(System.tmp_dir!(), "grasp-reload-#{System.unique_integer([:positive])}.json")

    document =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("functions", fn records ->
        Enum.reject(records, &(&1["id"] == @shout))
      end)

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
