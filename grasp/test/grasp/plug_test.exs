defmodule Grasp.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "plug-test", "version" => "0"}
    }
  }

  defp request(path, host \\ "127.0.0.1") do
    %{build_conn(:post, path, Jason.encode!(@initialize)) | host: host}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  test "a request for another path passes through untouched" do
    conn = Grasp.Plug.call(request("/users"), Grasp.Plug.init([]))

    refute conn.halted
    refute conn.state == :sent
  end

  test "a request from a host that is not loopback is refused" do
    conn = Grasp.Plug.call(request("/grasp/mcp", "evil.example"), Grasp.Plug.init([]))

    assert conn.halted
    assert response(conn, 403) == "forbidden"
  end

  test "the default path serves the MCP transport" do
    conn = Grasp.Plug.call(request("/grasp/mcp"), Grasp.Plug.init([]))

    assert conn.halted
    assert response(conn, 200) =~ ~s("serverInfo")
  end

  test "`:at` moves the endpoint and leaves the default path alone" do
    opts = Grasp.Plug.init(at: "/tools/grasp/mcp")

    conn = Grasp.Plug.call(request("/tools/grasp/mcp"), opts)
    assert response(conn, 200) =~ ~s("serverInfo")

    assert %Plug.Conn{halted: false} = Grasp.Plug.call(request("/grasp/mcp"), opts)
  end
end
