defmodule FluxClaw.Agents do
  @moduledoc false
  import Ecto.Query
  alias FluxClaw.Repo
  alias FluxClaw.Agents.{AgentSession, AgentMessage}
  alias FluxClaw.Projects

  def list_sessions do
    from(s in AgentSession, order_by: [desc: s.inserted_at])
    |> Repo.all()
  end

  def list_sessions_for_project(project_id) when is_binary(project_id) do
    from(s in AgentSession,
      where: s.project_id == ^project_id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  def get_session!(id), do: Repo.get!(AgentSession, id)

  def get_session(id), do: Repo.get(AgentSession, id)

  def create_session(attrs \\ %{}) do
    attrs =
      case Map.fetch(attrs, :project_id) do
        {:ok, pid} when is_binary(pid) ->
          attrs

        _ ->
          default = Projects.ensure_default_project()
          Map.put_new(attrs, :project_id, default.id)
      end

    %AgentSession{}
    |> AgentSession.changeset(Map.merge(%{title: "新对话"}, attrs))
    |> Repo.insert()
  end

  def update_session(%AgentSession{} = session, attrs) do
    session
    |> AgentSession.changeset(attrs)
    |> Repo.update()
  end

  def delete_session(%AgentSession{} = session) do
    Repo.delete(session)
  end

  def move_session_to_project(%AgentSession{} = session, project_id)
      when is_binary(project_id) do
    session
    |> AgentSession.changeset(%{project_id: project_id})
    |> Repo.update()
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

  def get_message(id), do: Repo.get(AgentMessage, id)

  def update_message(%AgentMessage{} = m, attrs) do
    m
    |> AgentMessage.changeset(attrs)
    |> Repo.update()
  end

  def delete_messages_after(%AgentMessage{} = anchor) do
    from(m in AgentMessage,
      where: m.session_id == ^anchor.session_id and m.inserted_at > ^anchor.inserted_at
    )
    |> Repo.delete_all()
  end

  @doc """
  Deletes the assistant message and everything after the preceding user message,
  so the agent can re-run from that user turn. Returns `:ok` or `{:error, :invalid}`.
  """
  def regenerate_from_assistant_message(session_id, assistant_id) do
    with %AgentMessage{} = assistant <- get_message(assistant_id),
         true <- to_string(assistant.session_id) == to_string(session_id),
         "assistant" <- assistant.role,
         %AgentMessage{role: "user"} = user <-
           previous_user_message_before(session_id, assistant_id) do
      _ = delete_messages_after(user)
      :ok
    else
      _ -> {:error, :invalid}
    end
  end

  defp previous_user_message_before(session_id, anchor_assistant_id) do
    session_id
    |> list_messages()
    |> Enum.split_while(&(&1.id != anchor_assistant_id))
    |> elem(0)
    |> Enum.reverse()
    |> Enum.find(&(&1.role == "user"))
  end
end
