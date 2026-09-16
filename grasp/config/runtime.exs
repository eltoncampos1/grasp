import Config

# An exported GRASP_INDEX or GRASP_PORT in a developer's shell must not reach the suite,
# which pins its own fixture index and port in config/test.exs.
if config_env() != :test do
  if index = System.get_env("GRASP_INDEX") do
    config :grasp, index_path: index
  end

  if editor = System.get_env("GRASP_EDITOR") do
    config :grasp, editor: editor
  end

  if command = System.get_env("GRASP_AGENT_COMMAND") do
    config :grasp, agent_command: command
  end

  if model = System.get_env("GRASP_AGENT_MODEL") do
    config :grasp, agent_model: model
  end

  if port = System.get_env("GRASP_PORT") do
    config :grasp, GraspWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end
end
