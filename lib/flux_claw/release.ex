defmodule FluxClaw.Release do
  @moduledoc "Database migrations for the bundled desktop/server release."
  def migrate do
    Application.load(:flux_claw)

    for repo <- Application.fetch_env!(:flux_claw, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
