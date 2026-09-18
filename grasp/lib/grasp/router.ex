defmodule Grasp.Router do
  @moduledoc """
  Mounts Grasp in a host application's router.

  Grasp runs inside the application it reviews rather than beside it, so it has no endpoint
  of its own to reach: the host owns the port, the session and the live socket, and Grasp
  contributes routes. `grasp/2` is the whole contribution — the review page and the two
  static files it loads, under one prefix. `Grasp.Plug`, in the host's endpoint, is the other
  half: it guards that prefix and serves the MCP endpoint agents connect to. Neither works
  properly without the other, and they must name the same prefix — but they name it
  differently. The macro's `path` is relative to the scope it is written in, as every route is,
  and is resolved against it with `Phoenix.Router.scoped_path/2`; the plug has no scope to
  resolve against, so its `:at` is the full path that resolution arrives at. A router that
  writes `scope "/tools" do grasp "/grasp" end` takes `plug Grasp.Plug, at: "/tools/grasp"`.

  The prefix is resolved at compile time and travels three ways, because three different
  readers need it: the route's `:private` carries it to the plug pipeline (the root layout
  builds asset URLs from it), the `live_session`'s `:session` carries it into the LiveView
  (whose links are built from it) and the scope carries it to the router's own matching.
  """

  @doc """
  Mounts the Grasp review page and its assets under `path`.

  Call it from a scope that runs the host's browser pipeline:

      import Grasp.Router

      scope "/" do
        pipe_through :browser
        grasp "/grasp"
      end

  `Grasp.Plug` goes in the host's endpoint with the same prefix, and is what keeps these
  routes off the public internet — a router pipeline is not enough, since a host cannot be
  asked to add a loopback check to the pipeline its own pages run through:

      plug Grasp.Plug, at: "/grasp"

  The plug's `:at` is the full path, enclosing scopes included, because it has no scope to
  resolve `path` against: inside `scope "/tools"`, `grasp "/grasp"` pairs with
  `at: "/tools/grasp"`.

  The MCP endpoint is that plug rather than a route here, because a browser pipeline declares
  `plug :accepts, ["html"]`, an MCP client asks for `application/json, text/event-stream`, and
  no route option can exempt a route from the pipeline that fronts it.

  ## Options

    * `:live_socket_path` — the path the host's endpoint declares in
      `socket "/live", Phoenix.LiveView.Socket`. Defaults to `"/live"`.

    * `:live_session_name` — the name of the generated `Phoenix.LiveView.Router.live_session/3`.
      Defaults to `:grasp`; a router that mounts Grasp twice needs a distinct name for the
      second mount.

    * `:on_mount` — a `Phoenix.LiveView.on_mount/1` callback, or a list of them, added to the
      live session. Defaults to none.

    * `:mcp_path` — where `Grasp.Plug` serves the transport, `path` with `mcp` under it by
      default, which is the plug's own default too. It is the address the chat panel hands the
      agent, so a host that gives the plug a `:mcp` of its own says so here as well.
  """
  @doc """
  Mounts Grasp into the router being compiled, without importing this module.

  A host that has Grasp in `:dev` only cannot write `import Grasp.Router` or `grasp "/grasp"`
  in its router: the compiler expands an import and a macro call while compiling the module,
  inside an `if` that is never taken as much as outside one, and in `:test` or `:prod` there
  is no `Grasp.Router` to expand. A function call to an absent module compiles, so the host
  writes

      if Code.ensure_loaded?(Grasp.Router), do: Grasp.Router.mount(__ENV__, "/grasp")

  and the routes exist exactly where the dependency does. The call writes into the router
  what `scope "/" do pipe_through :browser; grasp "/grasp" end` would have — `:pipeline`
  (default `:browser`) names the host pipeline, every other option is `grasp/2`'s — so the
  path is relative to the router's root and pairs with `plug Grasp.Plug, at: "/grasp"`.
  """
  @spec mount(Macro.Env.t(), String.t(), keyword()) :: :ok
  def mount(%Macro.Env{module: module} = env, path, opts \\ [])
      when is_atom(module) and not is_nil(module) and is_binary(path) and is_list(opts) do
    {pipeline, opts} = Keyword.pop(opts, :pipeline, :browser)

    quoted =
      quote do
        import Grasp.Router, only: [grasp: 1, grasp: 2]

        scope "/" do
          pipe_through unquote(pipeline)
          grasp unquote(path), unquote(opts)
        end
      end

    Module.eval_quoted(env, quoted)
    :ok
  end

  @spec grasp(String.t(), keyword()) :: Macro.t()
  defmacro grasp(path, opts \\ []) do
    quote bind_quoted: binding() do
      prefix = Grasp.Router.__prefix__(__MODULE__, path)
      {session_name, session_opts, route_opts} = Grasp.Router.__options__(prefix, opts)

      scope path, alias: false, as: false do
        import Phoenix.Router, only: [get: 4]
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

        live_session session_name, session_opts do
          live "/", GraspWeb.ReviewLive, :default, route_opts
          live "/s/:name", GraspWeb.ReviewLive, :session, route_opts
        end

        get "/assets/:asset", GraspWeb.Assets, :asset, route_opts
      end
    end
  end

  @doc false
  @spec __prefix__(module(), String.t()) :: String.t()
  def __prefix__(router, path) do
    router |> Phoenix.Router.scoped_path(path) |> String.replace_suffix("/", "")
  end

  @doc false
  @spec __options__(String.t(), keyword()) :: {atom(), keyword(), keyword()}
  def __options__(prefix, opts) do
    session_name = Keyword.get(opts, :live_session_name, :grasp)
    live_socket_path = Keyword.get(opts, :live_socket_path, "/live")
    mcp_path = Keyword.get(opts, :mcp_path, prefix <> "/mcp")
    on_mount = opts |> Keyword.get(:on_mount) |> List.wrap()

    session_opts = [
      session: {__MODULE__, :__session__, [prefix, mcp_path]},
      root_layout: {GraspWeb.Layouts, :root},
      layout: false,
      on_mount: on_mount
    ]

    route_opts = [private: %{grasp_path: prefix, live_socket_path: live_socket_path}]

    {session_name, session_opts, route_opts}
  end

  @doc false
  @spec __session__(Plug.Conn.t(), String.t(), String.t()) :: %{String.t() => String.t()}
  def __session__(%Plug.Conn{} = conn, prefix, mcp_path),
    do: %{"grasp_path" => __path__(conn, prefix), "mcp_path" => __path__(conn, mcp_path)}

  @doc false
  @spec __path__(Plug.Conn.t(), String.t()) :: String.t()
  def __path__(%Plug.Conn{script_name: script_name}, path),
    do: Enum.map_join(script_name, &("/" <> &1)) <> path
end
