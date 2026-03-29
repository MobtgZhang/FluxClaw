defmodule FluxClaw.Projects do
  @moduledoc false
  import Ecto.Query
  alias FluxClaw.Repo
  alias FluxClaw.Projects.Project

  def list_projects do
    from(p in Project, order_by: [asc: p.title, asc: p.inserted_at])
    |> Repo.all()
  end

  def get_project(id), do: Repo.get(Project, id)

  def get_project!(id), do: Repo.get!(Project, id)

  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(Map.merge(%{title: "新项目"}, attrs))
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  def ensure_default_project do
    case Repo.one(from p in Project, order_by: [asc: p.inserted_at], limit: 1) do
      %Project{} = p ->
        p

      nil ->
        {:ok, p} = create_project(%{title: "默认项目"})
        p
    end
  end
end
