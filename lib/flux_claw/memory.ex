defmodule FluxClaw.Memory do
  @moduledoc "L2/L3 persistence and recall helpers."
  import Ecto.Query
  alias FluxClaw.Repo
  alias FluxClaw.Memory.{Skill, Checkpoint}

  @global_skill_hint ~r/(全部技能|其他项目|别的项目|跨项目|all\s+skills|other\s+projects?)/iu

  def list_skills_for_prompt(query_text \\ "", project_id \\ nil)

  def list_skills_for_prompt(query_text, nil) do
    q = String.trim(query_text || "")
    list_skills_db(q, nil, 10) ++ external_skills_matching(q, 4)
  end

  def list_skills_for_prompt(query_text, project_id) when is_binary(project_id) do
    q = String.trim(query_text || "")
    limit = if q == "", do: 10, else: 8
    db = list_skills_db(q, project_id, limit)
    ext = external_skills_matching(q, 4)

    merged =
      if q != "" and Regex.match?(@global_skill_hint, q) do
        global = list_skills_db(q, nil, 6)
        dedupe_skills(db ++ global)
      else
        db
      end

    merged ++ ext
  end

  defp dedupe_skills(skills) do
    skills
    |> Enum.uniq_by(fn
      %Skill{id: id} -> id
      %{id: id} -> id
      m -> Map.get(m, :title) || Map.get(m, "title") || :unknown
    end)
  end

  defp list_skills_db(query_text, project_id, limit) do
    q = String.trim(query_text)

    base =
      from(s in Skill,
        order_by: [desc: s.inserted_at],
        limit: ^limit
      )

    base =
      if project_id do
        from(s in base, where: s.project_id == ^project_id)
      else
        base
      end

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

  defp external_skills_matching(query_text, limit) do
    q = String.trim(query_text) |> String.downcase()

    external_skill_paths()
    |> Enum.map(&load_external_md/1)
    |> Enum.filter(fn %{title: t, body: b} ->
      if q == "" do
        true
      else
        String.contains?(String.downcase(t <> " " <> b), q)
      end
    end)
    |> Enum.take(limit)
  end

  defp external_skill_paths do
    case cache_path(:external_skills) do
      root when is_binary(root) and root != "" ->
        if File.dir?(root) do
          root
          |> Path.join("**/*.{md,mdx,txt}")
          |> Path.wildcard()
        else
          []
        end

      _ ->
        []
    end
  end

  defp load_external_md(path) do
    case File.read(path) do
      {:ok, body} ->
        title = path |> Path.basename() |> Path.rootname()
        %{title: title <> " (external)", body: body, source: "external_file"}

      _ ->
        %{title: Path.basename(path), body: "", source: "external_file"}
    end
  end

  def cache_path(key) do
    paths = Application.get_env(:flux_claw, :cache_paths, []) || []
    Keyword.get(paths, key)
  end

  def create_skill(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def skills_to_prompt_block(skills) when is_list(skills) do
    skills
    |> Enum.map_join("\n\n---\n\n", fn s ->
      title = Map.get(s, :title) || Map.get(s, "title")
      body = Map.get(s, :body) || Map.get(s, "body")
      "### #{title}\n#{body}"
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

  def list_skills_for_project(project_id, limit \\ 32) when is_binary(project_id) do
    from(s in Skill,
      where: s.project_id == ^project_id,
      order_by: [desc: s.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def move_skill_to_project(skill_id, project_id)
      when is_binary(skill_id) and is_binary(project_id) do
    case Repo.get(Skill, skill_id) do
      nil -> {:error, :not_found}
      skill -> skill |> Skill.changeset(%{project_id: project_id}) |> Repo.update()
    end
  end

  def delete_skill(id) do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> Repo.delete(skill)
    end
  end

  def get_skill(id), do: Repo.get(Skill, id)

  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @doc "Markdown / text files under internal_skills and external_skills roots (for import UI)."
  def list_skill_import_files do
    roots =
      [cache_path(:internal_skills), cache_path(:external_skills)]
      |> Enum.filter(&(is_binary(&1) and &1 != "" and File.dir?(&1)))
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    roots
    |> Enum.flat_map(fn root ->
      root
      |> Path.join("**/*.{md,mdx,txt}")
      |> Path.wildcard()
    end)
    |> Enum.uniq()
    |> Enum.map(fn p ->
      exp = Path.expand(p)
      %{path: exp, name: Path.basename(exp)}
    end)
  end

  @doc "Markdown files under memory_root (read-only listing for sidebar)."
  def list_memory_markdown_docs do
    case cache_path(:memory_root) do
      root when is_binary(root) and root != "" ->
        r = Path.expand(root)

        if File.dir?(r) do
          r
          |> Path.join("**/*.{md,mdx,txt}")
          |> Path.wildcard()
          |> Enum.map(fn p ->
            exp = Path.expand(p)
            %{path: exp, name: Path.basename(exp)}
          end)
        else
          []
        end

      _ ->
        []
    end
  end

  def path_allowed_for_skill_import?(path) when is_binary(path) do
    exp = Path.expand(path)

    allowed =
      [cache_path(:internal_skills), cache_path(:external_skills)]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&Path.expand/1)

    Enum.any?(allowed, fn root -> String.starts_with?(exp, root) end)
  end

  def import_skill_from_file(path, project_id) when is_binary(path) and is_binary(project_id) do
    if not path_allowed_for_skill_import?(path) do
      {:error, :forbidden}
    else
      case File.read(path) do
        {:ok, body} ->
          title = path |> Path.basename() |> Path.rootname()

          create_skill(%{
            title: title,
            body: body,
            keywords: "",
            project_id: project_id,
            source: "file_import"
          })

        {:error, _} ->
          {:error, :read_failed}
      end
    end
  end

  @doc """
  自进化（harness2 风格）：把会话内的一个工作检查点（L1/working memory）结晶为
  持久技能（L3）。默认取最近的检查点；传 `:label` 可指定。
  """
  def promote_checkpoint_to_skill(session_id, opts \\ []) when is_binary(session_id) do
    label = Keyword.get(opts, :label)

    checkpoint =
      session_id
      |> list_checkpoints_for_session(50)
      |> then(fn cps ->
        if label, do: Enum.find(cps, &(&1.label == label)), else: List.first(cps)
      end)

    case checkpoint do
      nil ->
        {:error, :no_checkpoint}

      cp ->
        payload_note =
          case cp.payload do
            %{"note" => note} when is_binary(note) -> note
            %{note: note} when is_binary(note) -> note
            _ -> ""
          end

        body =
          Keyword.get(opts, :body) ||
            (payload_note != "" && payload_note) ||
            (is_binary(cp.label) && cp.label) ||
            ""

        title = Keyword.get(opts, :title) || cp.label || "Checkpoint skill"

        if body == "" do
          {:error, :empty_checkpoint}
        else
          create_skill(%{
            title: title,
            body: body,
            keywords: Keyword.get(opts, :keywords) || title,
            session_id: session_id,
            project_id: Keyword.get(opts, :project_id),
            source: "checkpoint_promotion"
          })
        end
    end
  end

  def append_evolution_log_line(session_id, line) when is_binary(line) do
    if Application.get_env(:flux_claw, :agents, [])[:self_evolve] == false do
      :ok
    else
      case cache_path(:memory_root) do
        root when is_binary(root) and root != "" ->
          File.mkdir_p!(Path.expand(root))
          path = Path.join(Path.expand(root), "evolution_log.md")

          stamp =
            DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")

          short = String.slice(session_id, 0, 8)
          block = "\n* #{stamp} — #{short} — #{line}\n"
          File.write!(path, block, [:append])

        _ ->
          :ok
      end
    end
  end

  @doc """
  自进化：将带工具调用的回合摘要追加到 `memory_root/evolution_episodes.md`，
  便于后续检索与技能结晶（经验回放式记录，不额外调用 LLM）。
  """
  def append_evolution_episode(session_id, user_text, tool_names, assistant_preview)
      when is_binary(session_id) do
    if Application.get_env(:flux_claw, :agents, [])[:self_evolve] == false do
      :ok
    else
      case cache_path(:memory_root) do
        root when is_binary(root) and root != "" ->
          File.mkdir_p!(Path.expand(root))
          path = Path.join(Path.expand(root), "evolution_episodes.md")

          stamp =
            DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

          ut =
            (user_text || "")
            |> String.replace("\n", " ")
            |> String.slice(0, 240)

          ap =
            (assistant_preview || "")
            |> String.replace("\n", " ")
            |> String.slice(0, 400)

          short = String.slice(session_id, 0, 8)

          block = """

          ### #{stamp} · #{short}
          - **用户**: #{ut}
          - **工具**: #{tool_names}
          - **助手摘要**: #{ap}
          """

          File.write!(path, block, [:append])

        _ ->
          :ok
      end
    end
  end
end
