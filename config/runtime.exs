import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/flux_claw start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :flux_claw, FluxClawWeb.Endpoint, server: true
end

if config_env() != :test do
  file_cfg = FluxClaw.ConfigLoader.load()

  default_cache = FluxClaw.ConfigLoader.default_cache_root()

  cache_root =
    System.get_env("FLUXCLAW_CACHE_ROOT") ||
      Map.get(file_cfg, :cache_root) ||
      default_cache

  cache_root = Path.expand(cache_root)

  sandbox_root =
    System.get_env("FLUX_CLAW_SANDBOX") ||
      Map.get(file_cfg, :flux_claw_sandbox) ||
      Path.expand("../tmp/flux_claw_sandbox", __DIR__)

  max_steps =
    case System.get_env("FLUXCLAW_MAX_STEPS") do
      nil ->
        Map.get(file_cfg, :agents_max_steps)

      "" ->
        nil

      s ->
        case Integer.parse(String.trim(s)) do
          {i, _} -> i
          _ -> nil
        end
    end

  if max_steps != nil do
    config :flux_claw, :agents, max_steps: max_steps
  end

  if Map.has_key?(file_cfg, :agents_self_evolve) do
    config :flux_claw, :agents, self_evolve: Map.fetch!(file_cfg, :agents_self_evolve)
  end

  if Map.has_key?(file_cfg, :agents_crystallize_skills) do
    config :flux_claw, :agents,
      crystallize_skills: Map.fetch!(file_cfg, :agents_crystallize_skills)
  end

  if Map.has_key?(file_cfg, :agents_crystallize_mode) do
    config :flux_claw, :agents, crystallize_mode: Map.fetch!(file_cfg, :agents_crystallize_mode)
  end

  config :flux_claw, :agents, sandbox_root: sandbox_root

  history_root =
    System.get_env("FLUXCLAW_CACHE_HISTORY") ||
      Map.get(file_cfg, :cache_history_root) ||
      Path.join(cache_root, "history")

  internal_skills =
    System.get_env("FLUXCLAW_CACHE_INTERNAL_SKILLS") ||
      Map.get(file_cfg, :cache_internal_skills) ||
      Path.join(cache_root, "skills")

  memory_root =
    System.get_env("FLUXCLAW_CACHE_MEMORY") ||
      Map.get(file_cfg, :cache_memory_root) ||
      Path.join(cache_root, "memory")

  external_skills =
    System.get_env("FLUXCLAW_CACHE_EXTERNAL_SKILLS") ||
      Map.get(file_cfg, :cache_external_skills) ||
      ""

  config :flux_claw, :llm,
    api_key: System.get_env("OPENAI_API_KEY") || Map.get(file_cfg, :openai_api_key),
    base_url:
      System.get_env("OPENAI_BASE_URL") ||
        Map.get(file_cfg, :openai_base_url) ||
        "https://api.openai.com/v1",
    model:
      System.get_env("OPENAI_MODEL") ||
        Map.get(file_cfg, :openai_model) ||
        "gpt-4o-mini",
    temperature: Map.get(file_cfg, :openai_temperature),
    top_p: Map.get(file_cfg, :openai_top_p),
    top_k: Map.get(file_cfg, :openai_top_k),
    llm_module: FluxClaw.LLM.OpenAI

  config :flux_claw, :cache_paths,
    cache_root: cache_root,
    external_skills: external_skills,
    internal_skills: internal_skills,
    history_root: history_root,
    memory_root: memory_root
end

config :flux_claw, FluxClawWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  default_db =
    Path.join([Application.app_dir(:flux_claw), "priv/repo/flux_claw_prod.db"])

  database_path = System.get_env("DATABASE_PATH") || default_db

  config :flux_claw, FluxClaw.Repo,
    adapter: Ecto.Adapters.SQLite3,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :flux_claw, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  desktop? = System.get_env("FLUXCLAW_DESKTOP") == "1"

  config :flux_claw, FluxClawWeb.Endpoint,
    url:
      if(desktop?,
        do: [
          host: "127.0.0.1",
          port: String.to_integer(System.get_env("PORT", "4000")),
          scheme: "http"
        ],
        else: [host: host, port: 443, scheme: "https"]
      ),
    check_origin:
      if(desktop?, do: ["http://127.0.0.1:" <> System.get_env("PORT", "4000")], else: true),
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: if(desktop?, do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 0})
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :flux_claw, FluxClawWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :flux_claw, FluxClawWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :flux_claw, FluxClaw.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

if System.get_env("FLUXCLAW_NODE") do
  config :flux_claw, :plugins, node: System.get_env("FLUXCLAW_NODE")
end
