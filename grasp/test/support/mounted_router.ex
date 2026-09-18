defmodule GraspWeb.MountedRouter do
  @moduledoc """
  A stand-in for a host application's router: Grasp under a prefix, inside a scope of its own.

  The standalone viewer mounts Grasp at the root, so the suite would otherwise never see a
  prefix that is not empty — and the prefix is what every link, asset URL and socket path on
  the page is built from.
  """

  use Phoenix.Router

  import Grasp.Router

  alias GraspWeb.TestOnMount

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/tools" do
    pipe_through :browser

    grasp "/grasp",
      live_session_name: :grasp_mounted,
      live_socket_path: "/socket/live",
      on_mount: TestOnMount
  end
end
