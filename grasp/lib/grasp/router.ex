defmodule Grasp.Router do
  @moduledoc """
  Mounts Grasp in a host application's router.

  Grasp runs inside the application it reviews rather than beside it, so it has no endpoint
  of its own to reach: the host owns the port, the session and the live socket, and Grasp
  contributes routes. `grasp/2` is the whole contribution — the review page, the two static
  files it loads and the MCP endpoint agents connect to, all under one prefix.

  The prefix is resolved at compile time and travels three ways, because three different
  readers need it: the route's `:private` carries it to the plug pipeline (the root layout
  builds asset URLs from it), the `live_session`'s `:session` carries it into the LiveView
  (whose links are built from it) and the scope carries it to the router's own matching.
  """

  @doc """
  Mounts the Grasp review page, its assets and its MCP endpoint under `path`.

  Call it from a scope that runs the host's browser pipeline:

      import Grasp.Router

      scope "/" do
        pipe_through :browser
        grasp "/grasp"
      end

  ## Options

    * `:live_socket_path` — the path the host's endpoint declares in
      `socket "/live", Phoenix.LiveView.Socket`. Defaults to `"/live"`.

    * `:live_session_name` — the name of the generated `Phoenix.LiveView.Router.live_session/3`.
      Defaults to `:grasp`; a router that mounts Grasp twice needs a distinct name for the
      second mount.

    * `:on_mount` — a `Phoenix.LiveView.on_mount/1` callback, or a list of them, added to the
      live session. Defaults to none.
  """
  @spec grasp(String.t(), keyword()) :: Macro.t()
  defmacro grasp(path, opts \\ []) do
    opts =
      if Macro.quoted_literal?(opts),
        do: Macro.prewalk(opts, &expand_alias(&1, __CALLER__)),
        else: opts

    quote bind_quoted: binding() do
      prefix = Grasp.Router.__prefix__(__MODULE__, path)
      {session_name, session_opts, route_opts} = Grasp.Router.__options__(prefix, opts)

      scope path, alias: false, as: false do
        import Phoenix.Router, only: [get: 4, forward: 4]
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

        live_session session_name, session_opts do
          live "/", GraspWeb.ReviewLive, :default, route_opts
          live "/s/:name", GraspWeb.ReviewLive, :session, route_opts
        end

        get "/assets/:asset", GraspWeb.Assets, :asset, route_opts

        # An MCP client carries neither a session nor a CSRF token, and the host's browser
        # pipeline rejects a POST without one. Route `:private` is merged into the connection
        # before the pipeline runs, so the exemption is in place by the time it is read.
        forward "/mcp", GraspWeb.Plugs.LocalOnlyMcp, [server: Grasp.MCP.Server],
          private: %{plug_skip_csrf_protection: true}
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
    on_mount = opts |> Keyword.get(:on_mount) |> List.wrap()

    session_opts = [
      session: {__MODULE__, :__session__, [prefix]},
      root_layout: {GraspWeb.Layouts, :root},
      layout: false,
      on_mount: on_mount
    ]

    route_opts = [private: %{grasp_path: prefix, live_socket_path: live_socket_path}]

    {session_name, session_opts, route_opts}
  end

  @doc false
  @spec __session__(Plug.Conn.t(), String.t()) :: %{String.t() => String.t()}
  def __session__(%Plug.Conn{}, prefix), do: %{"grasp_path" => prefix}

  defp expand_alias({:__aliases__, _meta, _parts} = alias, env),
    do: Macro.expand(alias, %{env | function: {:grasp, 2}})

  defp expand_alias(other, _env), do: other
end
