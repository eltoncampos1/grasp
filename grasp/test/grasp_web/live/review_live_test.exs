defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  test "renders the app shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Grasp"
  end
end
