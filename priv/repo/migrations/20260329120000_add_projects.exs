defmodule FluxClaw.Repo.Migrations.AddProjects do
  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      timestamps(type: :utc_datetime)
    end

    alter table(:agent_sessions) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:skills) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :source, :string
    end

    create index(:agent_sessions, [:project_id])
    create index(:skills, [:project_id])

    flush()

    default_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    execute """
    INSERT INTO projects (id, title, inserted_at, updated_at)
    VALUES ('#{default_id}', '默认项目', '#{now}', '#{now}')
    """

    execute """
    UPDATE agent_sessions SET project_id = '#{default_id}' WHERE project_id IS NULL
    """

    execute """
    UPDATE skills SET project_id = '#{default_id}', source = 'crystallized' WHERE project_id IS NULL
    """
  end

  def down do
    alter table(:skills) do
      remove :source
      remove :project_id
    end

    alter table(:agent_sessions) do
      remove :project_id
    end

    drop table(:projects)
  end
end
