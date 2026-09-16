import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  server: false,
  secret_key_base:
    "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-00"

config :grasp, index_path: "test/fixtures/index.json"

# The suite never runs the real CLI: this stand-in prints a canned stream-json run.
config :grasp, agent_command: Path.expand("test/support/fake_claude.sh", __DIR__ <> "/..")

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
