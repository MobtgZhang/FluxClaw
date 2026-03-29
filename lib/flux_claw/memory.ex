defmodule FluxClaw.Memory do
  @moduledoc "L2/L3 persistence and recall helpers."
  import Ecto.Query
  alias FluxClaw.Repo
  alias FluxClaw.Memory.{Skill, Checkpoint}

  def list_skills_for_prompt(query_text \\ "") when is_binary(query_text) do
    q = String.trim(query_text)

    base =
      from(s in Skill,
        order_by: [desc: s.inserted_at],
        limit: 8
      )

    base =
      if q != "" do
        pat = "%#{q}%"

        from(s in base,
          where:
            fragment("COALESCE(LOWER(?), '') LIKE LOWER(?)", s.keywords, ^pat) or
              fragment("COALESCE(LOWER(?), '') LIKE LOWER(?)", s.title, ^pat) or
              fragment("COALESCE(LOWER(?), '') LIKE LOWER(?)", s.body, ^pat)
        )
      else
        base
      end

    Repo.all(base)
  end

  def create_skill(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def skills_to_prompt_block(skills) when is_list(skills) do
    skills
    |> Enum.map_join("\n\n---\n\n", fn s ->
      "### #{s.title}\n#{s.body}"
    end)
  end

  def save_checkpoint(session_id, label, payload) when is_map(payload) do
    %Checkpoint{}
    |> Checkpoint.changeset(%{session_id: session_id, label: label, payload: payload})
    |> Repo.insert()
  end

  def list_checkpoints_for_session(session_id, limit \\ 24) do
    from(c in Checkpoint,
      where: c.session_id == ^session_id,
      order_by: [desc: c.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_skills_recent(limit \\ 32) do
    from(s in Skill, order_by: [desc: s.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  def delete_skill(id) do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> Repo.delete(skill)
    end
  end
end
