defmodule GraspWeb.MCPTest do
  use GraspWeb.ConnCase, async: true

  @greet "SampleApp.Greeter.greet/2"

  test "initialize, list tools, call one", %{conn: conn} do
    {conn, session} = initialize(conn)

    result = rpc(conn, session, "tools/list", %{})
    names = result["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

    assert names ==
             ~w(find_paths get_callees get_callers get_function list_entry_points list_modules list_sessions search_functions)

    assert Enum.all?(result["tools"], &(&1["description"] not in [nil, ""]))

    result =
      rpc(conn, session, "tools/call", %{
        "name" => "get_callees",
        "arguments" => %{"id" => @greet}
      })

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"callees" => callees} = Jason.decode!(text)
    assert "SampleApp.Formatter.wrap/1" in callees
  end

  test "a request addressed to another host is refused", %{conn: conn} do
    conn =
      %{conn | host: "evil.example"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "a loopback request a foreign page declares an origin for is refused", %{conn: conn} do
    conn =
      %{conn | host: "127.0.0.1"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "http://evil.example")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "the review page is served to any host", %{conn: conn} do
    assert %{conn | host: "evil.example"} |> get("/") |> html_response(200)
  end

  # -- helpers -------------------------------------------------------------

  defp initialize(conn) do
    conn =
      post_json(conn, nil, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        }
      })

    assert %{"result" => %{"serverInfo" => %{"name" => "grasp"}}} = decode(conn)
    [session] = get_resp_header(conn, "mcp-session-id")

    post_json(Phoenix.ConnTest.build_conn(), session, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })

    {Phoenix.ConnTest.build_conn(), session}
  end

  defp rpc(conn, session, method, params) do
    conn =
      post_json(conn, session, %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    assert %{"result" => result} = decode(conn)
    result
  end

  defp post_json(conn, session, body) do
    %{recycle(conn) | host: "127.0.0.1"}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(&if(session, do: put_req_header(&1, "mcp-session-id", session), else: &1))
    |> post("/mcp", Jason.encode!(body))
  end

  # The transport answers a POST either as one JSON document or as an SSE stream holding it.
  defp decode(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      ["text/event-stream" <> _] ->
        conn.resp_body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim() |> Jason.decode!()))
        |> List.last()

      _ ->
        Jason.decode!(conn.resp_body)
    end
  end
end
