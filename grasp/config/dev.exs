import Config

# Working on Grasp itself means running Grasp's own endpoint rather than mounting it in a
# host application.
config :grasp, standalone: true

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: ["//localhost", "//127.0.0.1"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-key-base-0000",
  watchers: [esbuild: {Esbuild, :install_and_run, [:grasp, ~w(--sourcemap=inline --watch)]}]

# esbuild builds the bundle Grasp ships in priv/static, so it is a dependency of
# developing Grasp rather than of running it.
config :esbuild,
  version: "0.25.4",
  grasp: [
    args:
      ~w(js/app.js --bundle --target=es2022 --entry-names=grasp --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
