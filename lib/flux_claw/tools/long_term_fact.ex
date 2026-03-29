defmodule FluxClaw.Tools.LongTermFact do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "start_long_term_update"

  @impl true
  def description, do: "Store a stable fact in session long-term memory (L2)."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        key: %{type: "string"},
        value: %{type: "string"}
      },
      required: ["key", "value"]
    }
  end

  @impl true
  def run(%{"key" => k, "value" => v}, _ctx) do
    {:ok, "remembered #{k}", [l2: %{k => v}]}
  end

  def run(_, _), do: {:error, "missing key or value"}
end
