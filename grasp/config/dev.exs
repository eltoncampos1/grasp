import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: ["//localhost", "//127.0.0.1"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-key-base-0000",
  watchers: [esbuild: {Esbuild, :install_and_run, [:grasp, ~w(--sourcemap=inline --watch)]}]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
