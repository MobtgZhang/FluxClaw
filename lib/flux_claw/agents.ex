defmodule FluxClaw.Agents do
  @moduledoc false
  import Ecto.Query
  alias FluxClaw.Repo
  alias FluxClaw.Agents.{AgentSession, AgentMessage}

  def list_sessions do
    from(s in AgentSession, order_by: [desc: s.inserted_at])
    |> Repo.all()
  end

  def get_session!(id), do: Repo.get!(AgentSession, id)

  def get_session(id), do: Repo.get(AgentSession, id)

  def create_session(attrs \\ %{}) do
    %AgentSession{}
    |> AgentSession.changeset(Map.merge(%{title: "新会话"}, attrs))
    |> Repo.insert()
  end

  def list_messages(session_id) do
    from(m in AgentMessage,
      where: m.session_id == ^session_id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  def append_message(session_id, attrs) do
    %AgentMessage{}
    |> AgentMessage.changeset(Map.put(attrs, :session_id, session_id))
    |> Repo.insert()
  end
end
