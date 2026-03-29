defmodule FluxClaw.Agents.AgentMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_messages" do
    field :role, :string
    field :content, :string
    field :tool_name, :string
    field :metadata, :map, default: %{}
    belongs_to :session, FluxClaw.Agents.AgentSession
    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:role, :content, :tool_name, :metadata, :session_id])
    |> validate_required([:role, :session_id])
  end
end
