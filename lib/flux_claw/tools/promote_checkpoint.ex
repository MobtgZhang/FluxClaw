defmodule FluxClaw.Tools.PromoteCheckpoint do
  @moduledoc false
  @behaviour FluxClaw.Tool

  alias FluxClaw.Memory

  @impl true
  def name, do: "promote_checkpoint"

  @impl true
  def description do
    "Self-evolution: promote a saved working checkpoint of this session into a durable L3 skill " <>
      "(harness2-style crystallization). Without arguments the latest checkpoint is promoted."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        label: %{
          type: "string",
          description: "Checkpoint label to promote; defaults to the latest one"
        },
        title: %{type: "string", description: "Skill title; defaults to the checkpoint label"},
        keywords: %{type: "string", description: "Optional retrieval keywords for the skill"},
        body: %{
          type: "string",
          description: "Optional skill body; defaults to the checkpoint note"
        }
      },
      required: []
    }
  end

  @impl true
  def run(args, ctx) when is_map(args) do
    project_id = project_id_for(ctx.session_id)

    opts = [
      label: Map.get(args, "label"),
      title: Map.get(args, "title"),
      keywords: Map.get(args, "keywords"),
      body: Map.get(args, "body"),
      project_id: project_id
    ]

    case Memory.promote_checkpoint_to_skill(ctx.session_id, opts) do
      {:ok, skill} ->
        {:ok,
         "promoted checkpoint to skill \"#{skill.title}\" (L3). It will be recalled in future sessions.",
         checkpoint: %{label: "promote_skill:#{skill.title}", payload: %{"skill_id" => skill.id}}}

      {:error, reason} ->
        {:error, "could not promote checkpoint: " <> inspect(reason)}
    end
  end

  def run(_, _), do: {:error, "invalid arguments"}

  defp project_id_for(session_id) do
    case FluxClaw.Agents.get_session(session_id) do
      %{project_id: pid} when is_binary(pid) -> pid
      _ -> nil
    end
  end
end
