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
          %{
            role: "assistant",
            content: text,
            reasoning: nil,
            tool_calls: [],
            finish_reason: "stop"
          }

        _ ->
          %{
            role: "assistant",
            content: "mock ok",
            reasoning: nil,
            tool_calls: [],
            finish_reason: "stop"
          }
      end

    {:ok, reply}
  end

  @impl true
  def stream(messages, _tools, _opts, callback) do
    {:ok, m} = complete(messages, [], [])

    if m[:reasoning] && m.reasoning != "" do
      for chunk <- chunk_utf8(m.reasoning, 3) do
        callback.({:reasoning_delta, chunk})
      end
    end

    content = m.content || ""

    if content != "" do
      for chunk <- chunk_utf8(content, 2) do
        callback.({:content_delta, chunk})
      end
    end

    callback.(:done)
    {:ok, m}
  end

  defp chunk_utf8(str, size) do
    str
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&IO.iodata_to_binary/1)
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
      reasoning: nil,
      tool_calls: [call],
      finish_reason: "tool_calls"
    }
  end
end
