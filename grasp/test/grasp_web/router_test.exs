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
    test "mounts the page and its assets under the prefix, and no MCP route" do
      assert routes(GraspWeb.MountedRouter) == [
               {:get, "/tools/grasp"},
               {:get, "/tools/grasp/s/:name"},
               {:get, "/tools/grasp/assets/:asset"}
             ]
    end

    test "hands the prefix to the live view through the live session" do
      assert %{name: :grasp_mounted, extra: extra} =
               live_session(GraspWeb.MountedRouter, "/tools/grasp/s/:name")

      assert extra.session ==
               {Grasp.Router, :__session__, ["/tools/grasp", "/tools/grasp/mcp"]}

      assert extra.root_layout == {GraspWeb.Layouts, :root}

      assert Grasp.Router.__session__(build_conn(), "/tools/grasp", "/tools/grasp/mcp") == %{
               "grasp_path" => "/tools/grasp",
               "mcp_path" => "/tools/grasp/mcp"
             }
    end

    test "an endpoint forwarded to from another is answered under its own script name" do
      conn = %{build_conn() | script_name: ["dev", "tools"]}

      assert Grasp.Router.__session__(conn, "/grasp", "/grasp/mcp") == %{
               "grasp_path" => "/dev/tools/grasp",
               "mcp_path" => "/dev/tools/grasp/mcp"
             }
    end

    test "an on_mount module written as an alias resolves in the host's router" do
      %{extra: extra} = live_session(GraspWeb.MountedRouter, "/tools/grasp")

      assert Enum.map(extra.on_mount, & &1.id) == [{GraspWeb.TestOnMount, :default}]
    end

    test "builds session links under the prefix" do
      assert Sidebar.session_path("/tools/grasp", "foo") == "/tools/grasp/s/foo"
      assert Sidebar.session_path("/tools/grasp", "default") == "/tools/grasp"
    end

    test "mounted at the root, the canvas is the root" do
      assert Sidebar.session_path("", "default") == "/"
      assert Sidebar.session_path("", "foo") == "/s/foo"
    end

    test "the standalone router mounts the same macro at the root", %{conn: conn} do
      assert routes(GraspWeb.Router) == [
               {:get, "/"},
               {:get, "/s/:name"},
               {:get, "/assets/:asset"}
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

      body = response(conn, 200)

      assert response_content_type(conn, :js) =~ "application/javascript"
      assert String.starts_with?(body, "var Phoenix =")
      # One marker per file, each unique to it: Grasp's own bundle names `LiveSocket` too.
      assert body =~ "var LiveView ="
      assert body =~ "PolyfillEvent"
      assert body =~ "Palette: palette_default"
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

  describe "mount/3" do
    test "writes the same routes as the macro, under the host's pipeline" do
      assert routes(GraspWeb.FunctionMountedRouter) == [
               {:get, "/review"},
               {:get, "/review/s/:name"},
               {:get, "/review/assets/:asset"}
             ]

      route =
        Enum.find(Phoenix.Router.routes(GraspWeb.FunctionMountedRouter), &(&1.path == "/review"))

      assert route.pipe_through == [:browser]
    end
  end
end
