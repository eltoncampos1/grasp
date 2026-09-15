defmodule GraspWeb.Endpoint do
  @moduledoc "HTTP endpoint of the Grasp viewer. Serves the bundled assets and the LiveView socket."

  use Phoenix.Endpoint, otp_app: :grasp

  @session_options [
    store: :cookie,
    key: "_grasp_key",
    signing_salt: "grasp-session-salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/", from: :grasp, gzip: false, only: GraspWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GraspWeb.Router
end
