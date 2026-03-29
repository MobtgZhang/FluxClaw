defmodule FluxClaw.LLM.OpenAI do
  @moduledoc "OpenAI-compatible Chat Completions (tools); streaming emits deltas from full response."
  @behaviour FluxClaw.LLM

  @impl true
  def complete(messages, tools, opts \\ []) do
    cfg = config()
    url = cfg.base_url <> "/chat/completions"
    api_key = cfg.api_key

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      body =
        %{
          model: Keyword.get(opts, :model, cfg.model),
          messages: messages,
          stream: false
        }
        |> maybe_put(:tools, tools)
        |> maybe_put(:tool_choice, Keyword.get(opts, :tool_choice))

      case Req.post(url,
             headers: headers(api_key),
             json: body,
             receive_timeout: Keyword.get(opts, :timeout, 120_000)
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, normalize_choice(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def stream(messages, tools, opts \\ [], callback) when is_function(callback, 1) do
    case complete(messages, tools, opts) do
      {:ok, %{content: content, tool_calls: tcs}} when is_binary(content) and content != "" ->
        callback.({:content_delta, content})
        callback.({:tool_calls, tcs || []})
        callback.(:done)
        :ok

      {:ok, %{content: nil, tool_calls: tcs} = _r} ->
        callback.({:tool_calls, tcs || []})
        callback.(:done)
        :ok

      {:ok, r} ->
        if is_binary(r.content) and r.content != "" do
          callback.({:content_delta, r.content})
        end

        callback.({:tool_calls, r.tool_calls || []})
        callback.(:done)
        :ok

      {:error, e} ->
        callback.({:error, e})
        {:error, e}
    end
  end

  defp normalize_choice(%{"choices" => [%{"message" => msg, "finish_reason" => fr} | _]}) do
    %{
      role: msg["role"] || "assistant",
      content: msg["content"],
      tool_calls: msg["tool_calls"] || [],
      finish_reason: fr
    }
  end

  defp normalize_choice(body),
    do: %{role: "assistant", content: inspect(body), tool_calls: [], finish_reason: "error"}

  defp config do
    case Application.get_env(:flux_claw, :llm, []) do
      list when is_list(list) -> Map.new(list)
      %{} = map -> map
      _ -> %{}
    end
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
