defmodule FluxClaw.LLM.Mock do
  @moduledoc false
  @behaviour FluxClaw.LLM

  @impl true
  def complete(messages, _tools, _opts) do
    reply =
      case Application.get_env(:flux_claw, :llm_mock_reply) do
        fun when is_function(fun, 1) ->
          fun.(messages)

        {:tool, name, args, text} ->
          tool_response(name, args, text)

        text when is_binary(text) ->
          %{role: "assistant", content: text, tool_calls: [], finish_reason: "stop"}

        _ ->
          %{role: "assistant", content: "mock ok", tool_calls: [], finish_reason: "stop"}
      end

    {:ok, reply}
  end

  @impl true
  def stream(messages, _tools, _opts, callback) do
    {:ok, m} = complete(messages, [], [])
    if m.content && m.content != "", do: callback.({:content_delta, m.content})
    callback.({:tool_calls, m.tool_calls || []})
    callback.(:done)
    :ok
  end

  defp tool_response(name, args, _after_text) do
    id = "call_mock"

    call = %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }

    %{
      role: "assistant",
      content: nil,
      tool_calls: [call],
      finish_reason: "tool_calls"
    }
  end
end
