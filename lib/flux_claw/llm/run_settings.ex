defmodule FluxClaw.LLM.RunSettings do
  @moduledoc "Validated, per-conversation model and reasoning preferences."

  def default_model do
    Application.get_env(:flux_claw, :llm, [])[:model] || ""
  end

  def levels(model) do
    model = String.downcase(model || "")

    cond do
      String.starts_with?(model, ["gpt-4", "gpt-3", "o1-mini", "o1-preview"]) -> ["auto"]
      String.contains?(model, "pro") and String.starts_with?(model, "gpt-5") -> ["auto", "high"]
      true -> ["auto", "low", "medium", "high"]
    end
  end

  def normalize(model, effort) do
    model = String.trim(model || "")
    effort = if effort in levels(model), do: effort, else: "auto"
    %{model: model, reasoning_effort: effort}
  end

  def from_session(nil), do: normalize(default_model(), "auto")

  def from_session(session),
    do: normalize(session.model || default_model(), session.reasoning_effort)

  def options(settings) do
    normalized = normalize(settings.model, settings.reasoning_effort)
    opts = if normalized.model == "", do: [], else: [model: normalized.model]

    if normalized.reasoning_effort == "auto",
      do: opts,
      else: opts ++ [reasoning_effort: normalized.reasoning_effort]
  end

  def reasoning_model?(model),
    do: String.starts_with?(String.downcase(model), ["gpt-5", "o1", "o3", "o4"])

  def label("low"), do: "快速"
  def label("medium"), do: "均衡"
  def label("high"), do: "深入"
  def label(_), do: "自动"
end
