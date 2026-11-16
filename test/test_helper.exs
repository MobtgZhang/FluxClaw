ExUnit.start(
  exclude: if(System.get_env("FLUXCLAW_PYTHON"), do: [], else: [harness2_runtime: true])
)

if System.find_executable("node") == nil do
  ExUnit.configure(exclude: [deepseek_plugins: true])
end

Ecto.Adapters.SQL.Sandbox.mode(FluxClaw.Repo, :manual)
