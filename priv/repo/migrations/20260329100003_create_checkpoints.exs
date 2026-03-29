defmodule FluxClaw.Repo.Migrations.CreateCheckpoints do
  use Ecto.Migration

  def change do
    create table(:checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:agent_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:checkpoints, [:session_id])
  end
end
