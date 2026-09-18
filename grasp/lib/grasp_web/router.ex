defmodule GraspWeb.Router do
  @moduledoc """
  The standalone viewer's router: a browser pipeline and Grasp mounted at the root.

  It mounts Grasp through the same macro a host application uses, and through a pipeline
  shaped like the one a generated Phoenix application already has, so working on Grasp
  exercises what a host will run rather than a second arrangement of the same routes.
  """

  use GraspWeb, :router

  import Grasp.Router

  # No loopback check: `Grasp.Plug`, in the endpoint, guards every path this router serves,
  # exactly as it guards a host's mount.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    grasp "/"
  end
end
