defmodule FluxClaw.Projects.Project do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :title, :string
    has_many :sessions, FluxClaw.Agents.AgentSession, foreign_key: :project_id
    has_many :skills, FluxClaw.Memory.Skill, foreign_key: :project_id
    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:title])
    |> validate_required([:title])
  end
end
