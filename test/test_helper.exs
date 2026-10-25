ExUnit.start()

if System.find_executable("node") == nil do
  ExUnit.configure(exclude: [deepseek_plugins: true])
end

Ecto.Adapters.SQL.Sandbox.mode(FluxClaw.Repo, :manual)
