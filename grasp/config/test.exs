import Config

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  server: false,
  secret_key_base:
    "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-00"

config :grasp, index_path: "test/fixtures/index.json"

# The fixture index names a project root that need not exist, and the suite must never write
# inside the repository: comments go to one temporary file per run.
config :grasp,
  comments_path:
    Path.join(System.tmp_dir!(), "grasp-test-#{System.os_time(:millisecond)}/comments.json")

# The suite never runs the real CLI: this stand-in prints a canned stream-json run.
config :grasp, agent_command: Path.expand("test/support/fake_claude.sh", __DIR__ <> "/..")

# Nor the real GitHub CLI: this stand-in answers canned pull request JSON.
config :grasp, gh_command: Path.expand("test/support/fake_gh.sh", __DIR__ <> "/..")

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
