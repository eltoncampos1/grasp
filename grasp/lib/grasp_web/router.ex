defmodule GraspWeb.Router do
  @moduledoc "Routes: the review page for the default session and for a named session."

  use GraspWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {GraspWeb.Layouts, :root}
  end

  scope "/", GraspWeb do
    pipe_through :browser

    live "/", ReviewLive
    live "/s/:name", ReviewLive
  end
end
