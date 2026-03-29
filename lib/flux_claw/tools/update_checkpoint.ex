defmodule FluxClaw.Tools.UpdateCheckpoint do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "update_working_checkpoint"

  @impl true
  def description, do: "Persist a working checkpoint (short working memory) for this session."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        label: %{type: "string"},
        note: %{type: "string"}
      },
      required: ["note"]
    }
  end

  @impl true
  def run(%{"note" => note} = args, ctx) do
    label = Map.get(args, "label", "checkpoint")
    payload = %{"note" => note}

    case FluxClaw.Memory.save_checkpoint(ctx.session_id, label, payload) do
      {:ok, _} -> {:ok, "checkpoint saved", [checkpoint: %{label: label, payload: payload}]}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  def run(_, _), do: {:error, "missing note"}
end
