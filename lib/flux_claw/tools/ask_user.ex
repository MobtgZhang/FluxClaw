defmodule FluxClaw.Tools.AskUser do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "ask_user"

  @impl true
  def description, do: "Ask the human a question and wait for an answer in the UI."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        question: %{type: "string"}
      },
      required: ["question"]
    }
  end

  @impl true
  def run(%{"question" => q}, _ctx) when is_binary(q) do
    ref = :erlang.unique_integer([:positive])
    {:suspend_ask, ref, q}
  end

  def run(_, _), do: {:error, "missing question"}
end
