defmodule FluxClaw.Repo.Migrations.CreateAgentMessages do
  use Ecto.Migration

  def change do
    create table(:agent_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:agent_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :content, :text
      add :tool_name, :string
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:agent_messages, [:session_id])
  end
end
