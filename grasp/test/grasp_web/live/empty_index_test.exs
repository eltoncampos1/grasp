defmodule GraspWeb.EmptyIndexTest do
  # The index lives in :persistent_term and the store is a singleton, so taking the index
  # away would be seen by every other test running at the same time.
  use GraspWeb.ConnCase, async: false

  @fixture Path.expand("../../fixtures/index.json", __DIR__)

  test "a project with no index yet is told which task writes one", %{conn: conn} do
    missing =
      Path.join(System.tmp_dir!(), "grasp-unwritten-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> restart_store(@fixture) end)
    restart_store(missing)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "No index at #{missing}"
    assert html =~ "mix grasp.index"
  end

  defp restart_store(path) do
    Application.put_env(:grasp, :index_path, path)
    :ok = Supervisor.terminate_child(Grasp.Supervisor, Grasp.IndexStore)
    {:ok, _pid} = Supervisor.restart_child(Grasp.Supervisor, Grasp.IndexStore)
    :ok
  end
end
