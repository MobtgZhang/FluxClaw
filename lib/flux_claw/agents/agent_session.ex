defmodule FluxClaw.Agents.AgentSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_sessions" do
    field :title, :string
    has_many :messages, FluxClaw.Agents.AgentMessage, foreign_key: :session_id
    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:title])
    |> validate_required([:title])
  end
end
