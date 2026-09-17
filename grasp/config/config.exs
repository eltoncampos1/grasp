import Config

config :grasp, GraspWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: GraspWeb.ErrorHTML], layout: false],
  pubsub_server: Grasp.PubSub,
  live_view: [signing_salt: "grasp-live-view-salt"]

config :grasp,
  index_path: nil,
  comments_path: nil,
  editor: nil,
  agent_command: "claude",
  agent_model: nil

config :esbuild,
  version: "0.25.4",
  grasp: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
