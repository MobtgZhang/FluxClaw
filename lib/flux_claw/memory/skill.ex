defmodule FluxClaw.Memory.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "skills" do
    field :title, :string
    field :body, :string
    field :keywords, :string
    belongs_to :session, FluxClaw.Agents.AgentSession
    timestamps(type: :utc_datetime)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:title, :body, :keywords, :session_id])
    |> validate_required([:title, :body])
  end
end
