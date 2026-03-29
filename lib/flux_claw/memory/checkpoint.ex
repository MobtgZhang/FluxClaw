defmodule FluxClaw.Memory.Checkpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "checkpoints" do
    field :label, :string
    field :payload, :map, default: %{}
    belongs_to :session, FluxClaw.Agents.AgentSession
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(cp, attrs) do
    cp
    |> cast(attrs, [:label, :payload, :session_id])
    |> validate_required([:payload, :session_id])
  end
end
