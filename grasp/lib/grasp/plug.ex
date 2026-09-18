defmodule Grasp.Plug do
  @moduledoc """
  Serves Grasp's MCP endpoint from the host's endpoint, in front of its router.

  The endpoint rather than the router, because a router pipeline is the wrong place for it:
  a browser pipeline declares `plug :accepts, ["html"]`, an MCP client asks for
  `application/json, text/event-stream`, and nothing a route can say exempts it — the
  request is refused before the route is reached. Sitting in the endpoint, the transport is
  reached before any pipeline runs, and the host's browser scope stays exactly as it was.

  The path is Grasp's mount path plus `mcp`, so a host that moves one moves the other:

      if code_reloading? do
        plug Grasp.Plug
      end

  Loopback is checked here as it is for the page, so the endpoint cannot be reached by a
  page whose DNS rebinds to `127.0.0.1`. Every request for another path passes through
  untouched.
  """

  @behaviour Plug

  @transport Anubis.Server.Transport.StreamableHTTP.Plug
  @default_at "/grasp/mcp"

  @typedoc "What `init/1` compiles the options into: the split path, and each plug's options."
  @opaque options :: {[String.t()], term(), term()}

  @doc """
  Compiles the options.

  `:at` is the path the MCP endpoint answers on, `"/grasp/mcp"` by default — Grasp's own
  default mount path with `mcp` under it.
  """
  @impl true
  @spec init(keyword()) :: options()
  def init(opts) do
    at = opts |> Keyword.get(:at, @default_at) |> split()

    {at, GraspWeb.Plugs.LocalOnly.init([]), @transport.init(server: Grasp.MCP.Server)}
  end

  @doc "Serves the MCP transport when the request is addressed to `:at`, and nothing otherwise."
  @impl true
  @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, {at, local_opts, transport_opts}) do
    case under(conn.path_info, at) do
      nil -> conn
      rest -> serve(conn, rest, local_opts, transport_opts)
    end
  end

  defp serve(%Plug.Conn{} = conn, rest, local_opts, transport_opts) do
    case GraspWeb.Plugs.LocalOnly.call(conn, local_opts) do
      %Plug.Conn{halted: true} = conn ->
        conn

      %Plug.Conn{} = conn ->
        conn |> Plug.forward(rest, @transport, transport_opts) |> Plug.Conn.halt()
    end
  end

  defp under(path, []), do: path
  defp under([segment | path], [segment | at]), do: under(path, at)
  defp under(_path, _at), do: nil

  defp split(path) when is_binary(path),
    do: for(segment <- String.split(path, "/"), segment != "", do: segment)
end
