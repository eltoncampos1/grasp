defmodule GraspWeb.FunctionMountedRouter do
  @moduledoc """
  A stand-in for a host that has Grasp in `:dev` only and so mounts it through
  `Grasp.Router.mount/3` behind `Code.ensure_loaded?/1`, never importing the module.
  """

  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  if Code.ensure_loaded?(Grasp.Router), do: Grasp.Router.mount(__ENV__, "/review")
end
