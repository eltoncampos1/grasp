defmodule GraspWeb.MountedEndpoint do
  @moduledoc """
  A stand-in for a host application's endpoint, serving `GraspWeb.MountedRouter`.

  Its live socket is deliberately not at `/live`: a host is free to declare its socket
  wherever it likes, and the page has to reach the one the host declared rather than the one
  Grasp's own endpoint happens to use.
  """

  use Phoenix.Endpoint, otp_app: :grasp

  @session_options [
    store: :cookie,
    key: "_host_key",
    signing_salt: "host-session-salt",
    same_site: "Lax"
  ]

  socket "/socket/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Grasp.Plug, at: "/tools/grasp"

  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GraspWeb.MountedRouter
end
