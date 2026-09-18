defmodule GraspWeb.RouterTest do
  use GraspWeb.ConnCase, async: true

  alias GraspWeb.Assets
  alias GraspWeb.Sidebar

  defp routes(router) do
    for route <- Phoenix.Router.routes(router), do: {route.verb, route.path}
  end

  defp live_session(router, path) do
    %{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}} =
      Enum.find(Phoenix.Router.routes(router), &(&1.path == path))

    live_session
  end

  describe "grasp/2" do
    test "mounts the page, its assets and the MCP endpoint under the prefix" do
      assert routes(GraspWeb.MountedRouter) == [
               {:get, "/tools/grasp"},
               {:get, "/tools/grasp/s/:name"},
               {:get, "/tools/grasp/assets/:asset"},
               {:*, "/tools/grasp/mcp"}
             ]
    end

    test "hands the prefix to the live view through the live session" do
      assert %{name: :grasp_mounted, extra: extra} =
               live_session(GraspWeb.MountedRouter, "/tools/grasp/s/:name")

      assert extra.session == {Grasp.Router, :__session__, ["/tools/grasp"]}
      assert extra.root_layout == {GraspWeb.Layouts, :root}

      assert Grasp.Router.__session__(build_conn(), "/tools/grasp") == %{
               "grasp_path" => "/tools/grasp"
             }
    end

    test "builds session links under the prefix" do
      assert Sidebar.session_path("/tools/grasp", "foo") == "/tools/grasp/s/foo"
      assert Sidebar.session_path("/tools/grasp", "default") == "/tools/grasp"
    end

    test "mounted at the root, the canvas is the root" do
      assert Sidebar.session_path("", "default") == "/"
      assert Sidebar.session_path("", "foo") == "/s/foo"
    end

    test "the MCP endpoint answers a POST carrying no CSRF token", %{conn: conn} do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "router-test", "version" => "0"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> post("/mcp", Jason.encode!(body))

      assert response(conn, 200) =~ ~s("serverInfo")
    end

    test "the standalone router mounts the same macro at the root", %{conn: conn} do
      assert routes(GraspWeb.Router) == [
               {:get, "/"},
               {:get, "/s/:name"},
               {:get, "/assets/:asset"},
               {:*, "/mcp"}
             ]

      html = conn |> get("/") |> html_response(200)

      assert html =~ ~s|src="/assets/grasp.js?vsn=#{Assets.hash("grasp.js")}"|
      assert html =~ ~s|href="/assets/grasp.css?vsn=#{Assets.hash("grasp.css")}"|
      assert html =~ ~s|phx-socket="/live"|
    end
  end

  describe "the assets route" do
    test "serves the host's Phoenix client in front of Grasp's bundle", %{conn: conn} do
      conn = get(conn, "/assets/grasp.js")

      assert response_content_type(conn, :js) =~ "application/javascript"
      assert String.starts_with?(response(conn, 200), "var Phoenix =")
      assert response(conn, 200) =~ "LiveSocket"
    end

    test "serves the stylesheet", %{conn: conn} do
      conn = get(conn, "/assets/grasp.css")

      assert response_content_type(conn, :css) =~ "text/css"
      assert response(conn, 200) =~ ".sidebar"
    end

    test "a request naming the current hash is cached forever", %{conn: conn} do
      conn = get(conn, "/assets/grasp.js?vsn=#{Assets.hash("grasp.js")}")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "a request naming no hash, or a stale one, is revalidated", %{conn: conn} do
      assert get_resp_header(get(conn, "/assets/grasp.css"), "cache-control") == ["no-cache"]

      assert get_resp_header(get(conn, "/assets/grasp.css?vsn=stale"), "cache-control") == [
               "no-cache"
             ]
    end

    test "any other name is not found", %{conn: conn} do
      assert conn |> get("/assets/nope.js") |> response(404) == "not found"
    end
  end
end
