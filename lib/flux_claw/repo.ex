defmodule FluxClaw.Repo do
  @adapter Application.compile_env(:flux_claw, FluxClaw.Repo)[:adapter] ||
             raise("set config :flux_claw, FluxClaw.Repo, adapter: ...")

  use Ecto.Repo,
    otp_app: :flux_claw,
    adapter: @adapter
end
