defmodule FluxClaw.Tools.AgentSearch do
  @moduledoc "Native adapter for SciPhi AgentSearch's local and hosted contracts."
  @behaviour FluxClaw.Tool
  def name, do: "agent_search"

  def description,
    do:
      "Search the configured AgentSearch knowledge index. Returns numbered sources with URLs and text. Requires a configured, populated AgentSearch service; never invent results when unavailable."

  def parameters do
    %{
      type: "object",
      properties: %{query: %{type: "string"}, limit: %{type: "integer", minimum: 1, maximum: 10}},
      required: ["query"],
      additionalProperties: false
    }
  end

  def run(%{"query" => query} = args, _ctx) when is_binary(query) do
    cfg = FluxClaw.Integrations.config()
    limit = args["limit"] || 5
    uri = URI.parse(cfg.search_url)

    cond do
      String.trim(query) == "" or byte_size(query) > 4000 ->
        {:error, "query must contain 1–4000 bytes"}

      not is_integer(limit) or limit not in 1..10 ->
        {:error, "limit must be 1–10"}

      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] ->
        {:error, "AgentSearch 未配置：在工具集成中填写已部署的服务地址。"}

      cfg.search_mode not in ["local", "sciphi"] ->
        {:error, "unknown AgentSearch mode"}

      true ->
        search(cfg, query, limit)
    end
  end

  def run(_, _), do: {:error, "missing query"}

  defp search(cfg, query, limit) do
    body =
      if cfg.search_mode == "sciphi",
        do: %{provider: "agent-search", query: query},
        else: %{
          query: query,
          limit_broad_results: 1000,
          limit_deduped_url_results: 100,
          limit_hierarchical_url_results: 25,
          limit_final_pagerank_results: limit
        }

    headers =
      if cfg.search_key == "", do: [], else: [{"authorization", "Bearer " <> cfg.search_key}]

    opts =
      [json: body, headers: headers, receive_timeout: 45_000, retry: false, redirect: false] ++
        FluxClaw.Integrations.request_options()

    case Req.post(String.trim_trailing(cfg.search_url, "/") <> "/search", opts) do
      {:ok, %{status: status, body: data}} when status in 200..299 ->
        results = if cfg.search_mode == "local" and is_map(data), do: data["results"], else: data

        if is_list(results) and Enum.all?(results, &is_map/1) do
          sources =
            results
            |> Enum.take(limit)
            |> Enum.with_index(1)
            |> Enum.map(fn {r, i} ->
              %{
                citation: "[#{i}]",
                title: text(r["title"], 500),
                url: text(r["url"], 2000),
                text: text(r["text"], 6000),
                score: r["score"]
              }
            end)

          {:ok, Jason.encode!(%{query: query, sources: sources, count: length(sources)})}
        else
          {:error, "AgentSearch returned an incompatible response"}
        end

      {:ok, %{status: status}} ->
        {:error, "AgentSearch HTTP #{status}; check service and credentials"}

      {:error, _} ->
        {:error, "AgentSearch request failed; check service availability"}
    end
  end

  defp text(s, n) when is_binary(s), do: String.slice(s, 0, n)
  defp text(_, _), do: ""
end
