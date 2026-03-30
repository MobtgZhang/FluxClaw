defmodule FluxClaw.Tools.TaskPlan do
  @moduledoc false
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "task_plan"

  @impl true
  def description do
    FluxClaw.Prompts.task_plan_tool_description()
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        title: %{type: "string", description: "One-line plan title"},
        steps: %{
          type: "array",
          items: %{type: "string"},
          description: "Ordered steps"
        }
      },
      required: ["steps"]
    }
  end

  @impl true
  def run(%{"steps" => steps} = args, _ctx) when is_list(steps) do
    title = Map.get(args, "title", "Plan")
    lines = steps |> Enum.with_index(1) |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{s}" end)
    text = "#{title}\n#{lines}"
    {:ok, text, l1: %{last_plan: text}}
  end

  def run(_, _), do: {:error, "missing steps"}
end
