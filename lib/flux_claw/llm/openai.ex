defmodule FluxClaw.LLM.OpenAI do
  @moduledoc "OpenAI-compatible Chat Completions (tools); SSE streaming with content/reasoning deltas."
  @behaviour FluxClaw.LLM

  @doc """
  Fetches model ids from `GET {base_url}/models` (OpenAI-compatible).
  Returns sorted unique ids, or `{:error, reason}`.
  """
  def list_models do
    cfg = config()
    url = String.trim_trailing(to_string(cfg[:base_url] || ""), "/") <> "/models"
    api_key = cfg[:api_key]

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      case Req.get(url, headers: headers(api_key), receive_timeout: 60_000) do
        {:ok, %{status: 200, body: body}} ->
          body = decode_json_body(body)
          ids = extract_model_ids(body)
          {:ok, ids |> Enum.uniq() |> Enum.sort()}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_json_body(body) when is_map(body), do: body

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp decode_json_body(_), do: %{}

  defp extract_model_ids(%{"data" => list}) when is_list(list) do
    for m <- list, id <- [Map.get(m, "id")], is_binary(id), do: id
  end

  defp extract_model_ids(%{"models" => list}) when is_list(list) do
    for m <- list, id <- [Map.get(m, "id")], is_binary(id), do: id
  end

  defp extract_model_ids(_), do: []

  @impl true
  def complete(messages, tools, opts \\ []) do
    cfg = config()
    url = cfg.base_url <> "/chat/completions"
    api_key = cfg.api_key

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      body = request_body(messages, tools, opts, cfg.model, false)

      case Req.post(url,
             headers: headers(api_key),
             json: body,
             retry: Keyword.get(opts, :retry, :safe_transient),
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
    cfg = config()
    url = cfg.base_url <> "/chat/completions"
    api_key = cfg.api_key

    if is_nil(api_key) or api_key == "" do
      callback.({:error, :missing_api_key})
      {:error, :missing_api_key}
    else
      tid = :ets.new(:openai_sse, [:set, :private])

      try do
        :ets.insert(tid, {:buffer, ""})
        :ets.insert(tid, {:content, ""})
        :ets.insert(tid, {:reasoning, ""})
        :ets.insert(tid, {:calls, %{}})
        :ets.insert(tid, {:finish_reason, nil})

        body = request_body(messages, tools, opts, cfg.model, true)

        result =
          Req.post(url,
            headers: headers(api_key),
            json: body,
            receive_timeout: Keyword.get(opts, :timeout, 120_000),
            into: fn {:data, data}, wr ->
              handle_stream_bytes(tid, data, callback)
              {:cont, wr}
            end
          )

        case result do
          {:ok, %{status: 200}} ->
            flush_stream_buffer(tid, callback)
            final = build_choice_from_ets(tid)
            callback.(:done)
            {:ok, final}

          {:ok, %{status: status, body: body}} ->
            err = {:http, status, body}
            callback.({:error, err})
            {:error, err}

          {:error, reason} ->
            callback.({:error, reason})
            {:error, reason}
        end
      after
        :ets.delete(tid)
      end
    end
  end

  defp request_body(messages, tools, opts, model, stream?) do
    cfg = config()

    selected = Keyword.get(opts, :model, model)
    reasoning? = FluxClaw.LLM.RunSettings.reasoning_model?(selected)

    %{
      model: selected,
      messages: messages,
      stream: stream?
    }
    |> maybe_put(:tools, tools)
    |> maybe_put(:tool_choice, Keyword.get(opts, :tool_choice))
    |> maybe_put(:reasoning_effort, Keyword.get(opts, :reasoning_effort))
    |> maybe_put(
      :temperature,
      if(!reasoning?, do: Keyword.get(opts, :temperature) || cfg[:temperature])
    )
    |> maybe_put(:top_p, if(!reasoning?, do: Keyword.get(opts, :top_p) || cfg[:top_p]))
  end

  defp handle_stream_bytes(tid, data, callback) do
    buf = ets_get(tid, :buffer, "")
    combined = buf <> data
    {lines, rest} = take_complete_lines(combined)
    :ets.insert(tid, {:buffer, rest})
    Enum.each(lines, &process_sse_line(tid, &1, callback))
  end

  defp flush_stream_buffer(tid, callback) do
    case ets_get(tid, :buffer, "") |> String.trim() do
      "" -> :ok
      line -> process_sse_line(tid, line, callback)
    end

    :ets.insert(tid, {:buffer, ""})
  end

  defp take_complete_lines(bin) do
    case String.split(bin, "\n") do
      [] ->
        {[], ""}

      parts ->
        case List.last(parts) do
          nil ->
            {[], ""}

          last ->
            if String.ends_with?(bin, "\n") do
              {parts, ""}
            else
              {Enum.drop(parts, -1), last}
            end
        end
    end
  end

  defp process_sse_line(tid, line, callback) do
    line = String.trim(line)

    if String.starts_with?(line, "data: ") do
      payload = line |> String.slice(5..-1//1) |> String.trim()

      cond do
        payload == "" or payload == "[DONE]" ->
          :ok

        true ->
          case Jason.decode(payload) do
            {:ok, %{"error" => err}} ->
              callback.({:error, {:api, err}})

            {:ok, obj} ->
              apply_choice_delta(tid, obj, callback)

            _ ->
              :ok
          end
      end
    end
  end

  defp apply_choice_delta(tid, obj, callback) do
    case obj["choices"] do
      [choice | _] ->
        delta = choice["delta"] || %{}

        if fr = choice["finish_reason"] do
          :ets.insert(tid, {:finish_reason, fr})
        end

        emit_text_delta(
          tid,
          :reasoning,
          delta["reasoning_content"] || delta["reasoning"],
          callback,
          :reasoning_delta
        )

        emit_text_delta(tid, :content, delta["content"], callback, :content_delta)
        merge_tool_call_deltas(tid, delta["tool_calls"])

      _ ->
        :ok
    end
  end

  defp emit_text_delta(_tid, _key, nil, _callback, _ev), do: :ok
  defp emit_text_delta(_tid, _key, "", _callback, _ev), do: :ok

  defp emit_text_delta(tid, key, piece, callback, ev) when is_binary(piece) do
    cur = ets_get(tid, key, "")
    :ets.insert(tid, {key, cur <> piece})
    callback.({ev, piece})
  end

  defp merge_tool_call_deltas(_tid, nil), do: :ok
  defp merge_tool_call_deltas(_tid, []), do: :ok

  defp merge_tool_call_deltas(tid, parts) when is_list(parts) do
    calls = ets_get(tid, :calls, %{})

    calls =
      Enum.reduce(parts, calls, fn tc, acc ->
        idx = tc["index"] || 0
        fn_map = tc["function"] || %{}
        cur = Map.get(acc, idx, %{id: nil, name: nil, arguments: ""})

        cur = if id = tc["id"], do: %{cur | id: id}, else: cur
        cur = if n = fn_map["name"], do: %{cur | name: n}, else: cur
        arg = fn_map["arguments"] || ""
        cur = %{cur | arguments: (cur.arguments || "") <> arg}
        Map.put(acc, idx, cur)
      end)

    :ets.insert(tid, {:calls, calls})
  end

  defp build_choice_from_ets(tid) do
    content = ets_get(tid, :content, "")
    reasoning = ets_get(tid, :reasoning, "")
    fr = ets_get(tid, :finish_reason, "stop")
    tool_calls = build_tool_calls_list(ets_get(tid, :calls, %{}))

    %{
      role: "assistant",
      content: if(content == "", do: nil, else: content),
      reasoning: if(reasoning == "", do: nil, else: reasoning),
      tool_calls: tool_calls,
      finish_reason: fr
    }
  end

  defp build_tool_calls_list(map) when map == %{}, do: []

  defp build_tool_calls_list(map) do
    map
    |> Enum.sort_by(fn {i, _} -> i end)
    |> Enum.map(fn {i, %{id: id, name: name, arguments: args}} ->
      %{
        "id" => id || "call_#{i}",
        "type" => "function",
        "function" => %{
          "name" => name || "",
          "arguments" => args || "{}"
        }
      }
    end)
    |> Enum.reject(fn tc -> tc["function"]["name"] in [nil, ""] end)
  end

  defp ets_get(tid, key, default) do
    case :ets.lookup(tid, key) do
      [{^key, v}] -> v
      _ -> default
    end
  end

  defp normalize_choice(%{"choices" => [%{"message" => msg, "finish_reason" => fr} | _]}) do
    %{
      role: msg["role"] || "assistant",
      content: msg["content"],
      reasoning: msg["reasoning_content"] || msg["reasoning"],
      tool_calls: msg["tool_calls"] || [],
      finish_reason: fr
    }
  end

  defp normalize_choice(body),
    do: %{
      role: "assistant",
      content: inspect(body),
      reasoning: nil,
      tool_calls: [],
      finish_reason: "error"
    }

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
