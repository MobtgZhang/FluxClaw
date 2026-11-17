defmodule FluxClaw.Agents.AgentSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_sessions" do
    field :title, :string
    field :model, :string
    field :reasoning_effort, :string, default: "auto"
    field :execution_mode, :string, default: "agent"
    belongs_to :project, FluxClaw.Projects.Project
    has_many :messages, FluxClaw.Agents.AgentMessage, foreign_key: :session_id
    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:title, :project_id, :model, :reasoning_effort, :execution_mode])
    |> validate_required([:title])
    |> validate_length(:model, max: 200)
    |> validate_format(:model, ~r/^\S+$/)
    |> validate_inclusion(:reasoning_effort, ["auto", "low", "medium", "high"])
    |> validate_required([:execution_mode])
    |> validate_inclusion(:execution_mode, ["agent", "plan"])
  end
end
