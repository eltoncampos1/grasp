defmodule Grasp.Plug do
  @moduledoc """
  Guards Grasp's mount and serves its MCP endpoint, from the host's endpoint in front of its
  router.

      if code_reloading? do
        plug Grasp.Plug
      end

  Two jobs under one prefix, because they share a reason to run before the router.

  The **guard** is why binding a dev server to `127.0.0.1` is not enough on its own: a page
  on an attacker's domain whose DNS rebinds to `127.0.0.1` becomes same-origin with the
  server, and Grasp then hands it every indexed function's source — and, through the chat
  panel, an agent that edits files. `GraspWeb.Plugs.LocalOnly` checks the `Host` the request
  was addressed to and the `Origin` the browser declares, and it has to run for the page and
  its assets, not only for the MCP endpoint. A host's own pipeline cannot be relied on for
  that, so the guard sits here.

  The **transport** is here rather than in the router because a browser pipeline declares
  `plug :accepts, ["html"]`, an MCP client asks for `application/json, text/event-stream`,
  and nothing a route can say exempts it — the request is refused before the route is
  reached. Before any pipeline, the transport is reached at all, and the host's browser
  scope stays exactly as it was.

  Everything else under the prefix passes through to the router once it has been checked;
  every request outside the prefix passes through untouched.
  """

  @behaviour Plug

  @transport Anubis.Server.Transport.StreamableHTTP.Plug
  @default_at "/grasp"

  @typedoc "What `init/1` compiles the options into: two split paths and each plug's options."
  @opaque options :: %{
            at: [String.t()],
            mcp: [String.t()],
            local: term(),
            transport: term()
          }

  @doc """
  Compiles the options.

  * `:at` — the prefix Grasp is mounted at, `"/grasp"` by default. It must be the *full* path
    the router answers Grasp on, enclosing scopes included: a router that writes
    `scope "/tools" do grasp "/grasp" end` serves Grasp at `/tools/grasp`, so the plug takes
    `at: "/tools/grasp"`. The plug guards what the router serves, and a prefix that names less
    leaves part of the page unguarded. `"/"` guards the whole application, which is what
    Grasp's own standalone server wants and what a host does not.

  * `:mcp` — where the MCP transport answers, `:at` with `mcp` under it by default. It has to
    lie under `:at`, since that is the only path the plug ever looks at, and `init/1` raises
    if it does not. A host that sets this sets `Grasp.Router.grasp/2`'s `:mcp_path` to the same
    value, since that is the address the chat panel hands the agent.
  """
  @impl true
  @spec init(keyword()) :: options()
  def init(opts) do
    at = opts |> Keyword.get(:at, @default_at) |> split()

    mcp =
      case Keyword.fetch(opts, :mcp) do
        {:ok, path} -> under!(split(path), at, path, opts)
        :error -> at ++ ["mcp"]
      end

    %{
      at: at,
      mcp: mcp,
      local: GraspWeb.Plugs.LocalOnly.init([]),
      transport: @transport.init(server: Grasp.MCP.Server)
    }
  end

  @doc "Checks a request under `:at` for loopback, and serves the one addressed to `:mcp`."
  @impl true
  @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: path} = conn, %{at: at} = opts) do
    if under?(path, at), do: guard(conn, opts), else: conn
  end

  defp guard(%Plug.Conn{} = conn, opts) do
    case GraspWeb.Plugs.LocalOnly.call(conn, opts.local) do
      %Plug.Conn{halted: true} = conn -> conn
      %Plug.Conn{} = conn -> serve(conn, opts)
    end
  end

  defp serve(%Plug.Conn{path_info: path} = conn, opts) do
    case under(path, opts.mcp) do
      nil -> conn
      rest -> conn |> Plug.forward(rest, @transport, opts.transport) |> Plug.Conn.halt()
    end
  end

  defp under!(mcp, at, path, opts) do
    if under?(mcp, at) do
      mcp
    else
      raise ArgumentError,
            "Grasp.Plug's :mcp must lie under :at, since :at is the only prefix the plug " <>
              "looks at. Got mcp: #{inspect(path)} under at: " <>
              "#{inspect(Keyword.get(opts, :at, @default_at))}."
    end
  end

  defp under?(path, prefix), do: under(path, prefix) != nil

  defp under(path, []), do: path
  defp under([segment | path], [segment | prefix]), do: under(path, prefix)
  defp under(_path, _prefix), do: nil

  defp split(path) when is_binary(path),
    do: for(segment <- String.split(path, "/"), segment != "", do: segment)
end
