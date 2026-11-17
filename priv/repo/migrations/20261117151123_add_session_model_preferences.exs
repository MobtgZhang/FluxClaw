defmodule FluxClaw.Repo.Migrations.AddSessionModelPreferences do
  use Ecto.Migration

  def change do
    alter table(:agent_sessions) do
      add :model, :string
      add :reasoning_effort, :string, default: "auto"
    end
  end
end
