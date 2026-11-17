defmodule FluxClaw.Test.CapturingLLM do
  @behaviour FluxClaw.LLM
  def complete(messages, tools, opts) do
    send(Application.fetch_env!(:flux_claw, :llm_capture_owner), {:model_request, messages, opts})
    send(Application.fetch_env!(:flux_claw, :llm_capture_owner), {:model_tools, tools})
    {:ok, %{content: "done", tool_calls: [], reasoning: nil}}
  end

  def stream(messages, tools, opts, callback) do
    result = complete(messages, tools, opts)
    callback.(:done)
    result
  end
end
