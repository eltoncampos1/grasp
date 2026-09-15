import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  server: false,
  secret_key_base:
    "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-00"

config :grasp, index_path: "test/fixtures/index.json"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
