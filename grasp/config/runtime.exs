import Config

if index = System.get_env("GRASP_INDEX") do
  config :grasp, index_path: index
end

if editor = System.get_env("GRASP_EDITOR") do
  config :grasp, editor: editor
end

if port = System.get_env("GRASP_PORT") do
  config :grasp, GraspWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
end
