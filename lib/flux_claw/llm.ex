defmodule FluxClaw.LLM do
  @moduledoc "LLM adapter behaviour (OpenAI-compatible chat completions)."

  @type message :: map()
  @type tool_spec :: map()

  @doc "Non-streaming completion; returns assistant turn with optional tool_calls."
  @callback complete(messages :: [message()], tools :: [tool_spec()], opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Streams SSE chunks. Callback may receive:
  `{:reasoning_delta, binary}`, `{:content_delta, binary}`, `:done`, `{:error, term}`.

  Returns `{:ok, final_choice_map}` (same shape as `complete/3`) or `{:error, term}`.
  """
  @callback stream(
              messages :: [message()],
              tools :: [tool_spec()],
              opts :: keyword(),
              callback :: (term() -> any)
            ) ::
              {:ok, map()} | {:error, term()}

  def impl do
    Application.get_env(:flux_claw, :llm, [])[:llm_module] || FluxClaw.LLM.OpenAI
  end
end
