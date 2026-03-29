# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :flux_claw,
  ecto_repos: [FluxClaw.Repo],
  generators: [timestamp_type: :utc_datetime]

config :flux_claw, FluxClaw.Repo, adapter: Ecto.Adapters.SQLite3

config :flux_claw, :agents,
  max_steps: 32,
  crystallize_skills: true

config :flux_claw, :memory_l0,
  rules: [
    "You are FluxClaw, a careful assistant with access to tools. Prefer safe, minimal changes.",
    "Stay within the sandbox directory for all file operations.",
    "If uncertain, use ask_user to confirm with the human."
  ]

# Configure the endpoint
config :flux_claw, FluxClawWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FluxClawWeb.ErrorHTML, json: FluxClawWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FluxClaw.PubSub,
  live_view: [signing_salt: "WqIfLaCR"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :flux_claw, FluxClaw.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  flux_claw: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  flux_claw: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :agent_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
