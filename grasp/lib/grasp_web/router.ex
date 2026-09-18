defmodule GraspWeb.Router do
  @moduledoc """
  The standalone viewer's router: one pipeline and Grasp mounted at the root.

  It mounts Grasp through the same macro a host application uses, so working on Grasp
  exercises the mounted form rather than a second arrangement of the same routes — and the
  pipeline is the one a host is asked for, so what the suite proves is what the README tells
  a host to write.
  """

  use GraspWeb, :router

  import Grasp.Router

  # No `:accepts` plug: the MCP endpoint under the same prefix speaks JSON and server-sent
  # events, and a pipeline that admits HTML alone refuses it before the route is reached.
  pipeline :grasp_browser do
    plug GraspWeb.Plugs.LocalOnly
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :grasp_browser

    grasp("/")
  end
end
