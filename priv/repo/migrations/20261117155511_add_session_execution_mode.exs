defmodule FluxClaw.Repo.Migrations.AddSessionExecutionMode do
  use Ecto.Migration

  def change do
    alter table(:agent_sessions) do
      add :execution_mode, :string, null: false, default: "agent"
    end
  end
end
