defmodule FluxClaw.LLM do
  @moduledoc "LLM adapter behaviour (OpenAI-compatible chat completions)."

  @type message :: map()
  @type tool_spec :: map()

  @doc "Non-streaming completion; returns assistant turn with optional tool_calls."
  @callback complete(messages :: [message()], tools :: [tool_spec()], opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Streams SSE chunks; events: {:content_delta, binary}, {:tool_calls, list}, :done, {:error, term}"
  @callback stream(
              messages :: [message()],
              tools :: [tool_spec()],
              opts :: keyword(),
              callback :: (term() -> any)
            ) ::
              :ok | {:error, term()}

  def impl do
    Application.get_env(:flux_claw, :llm, [])[:llm_module] || FluxClaw.LLM.OpenAI
  end
end
