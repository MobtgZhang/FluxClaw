defmodule FluxClaw.Repo.Migrations.ClearExistingSkills do
  use Ecto.Migration

  def up do
    execute("DELETE FROM skills")
  end

  def down do
    :ok
  end
end
