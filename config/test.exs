import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flux_claw, FluxClaw.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: Path.expand("../test/flux_claw_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :flux_claw, FluxClawWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pw6T3YQxPBS73pkKf4YwUjRfYV1h6H58UfKxrlVt8ZlAQ12AAGt3GIFZcly8+t/I",
  server: false

# In test we don't send emails
config :flux_claw, FluxClaw.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :flux_claw, :llm,
  llm_module: FluxClaw.LLM.Mock,
  api_key: "test",
  base_url: "http://localhost",
  model: "mock"

config :flux_claw, :agents,
  crystallize_skills: false,
  self_evolve: false,
  sandbox_root: Path.expand("../tmp/test_flux_claw_sandbox", __DIR__)
