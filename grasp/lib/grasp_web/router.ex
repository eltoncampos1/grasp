defmodule GraspWeb.Router do
  @moduledoc """
  Routes: the review page for the default session and for a named session, plus the MCP
  endpoint agents connect to.
  """

  use GraspWeb, :router

  pipeline :browser do
    plug GraspWeb.Plugs.LocalOnly
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {GraspWeb.Layouts, :root}
  end

  pipeline :mcp do
    plug GraspWeb.Plugs.LocalOnly
  end

  scope "/", GraspWeb do
    pipe_through :browser

    live "/", ReviewLive
    live "/s/:name", ReviewLive
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: Grasp.MCP.Server
  end
end
