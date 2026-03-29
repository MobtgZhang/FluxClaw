defmodule FluxClaw.Tools.WebFetch do
  @moduledoc false
  @behaviour FluxClaw.Tool
  @max_body 200_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description do
    "HTTP GET a public http(s) URL and return extracted text (HTML simplified). " <>
      "Not for authenticated APIs."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        url: %{type: "string", description: "http or https URL"}
      },
      required: ["url"]
    }
  end

  @impl true
  def run(%{"url" => url}, _ctx) when is_binary(url) do
    with :ok <- validate_url(url),
         {:ok, resp} <-
           Req.get(url,
             redirect: true,
             max_redirects: 5,
             receive_timeout: 45_000,
             retry: :transient,
             max_retries: 1
           ) do
      status = resp.status
      body = resp.body || ""

      if status in 200..299 do
        text =
          body
          |> to_string()
          |> String.slice(0, @max_body)
          |> html_to_text()

        {:ok, "来源: #{url}\n\n" <> text}
      else
        {:error, "HTTP #{status}"}
      end
    else
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  def run(_, _), do: {:error, "missing url"}

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "only http/https allowed"}

      uri.host in [nil, ""] ->
        {:error, "invalid url"}

      block_private_host?(uri.host) ->
        {:error, "private or local hosts are not allowed"}

      true ->
        :ok
    end
  end

  defp block_private_host?(host) do
    h = String.downcase(host)

    h in ["localhost", "127.0.0.1", "::1", "0.0.0.0"] or
      String.ends_with?(h, ".local") or
      String.starts_with?(h, "192.168.") or
      String.starts_with?(h, "10.") or
      String.starts_with?(h, "172.16.") or
      match?({:ok, {10, _, _, _}}, :inet.parse_address(String.to_charlist(host))) or
      match?({:ok, {127, _, _, _}}, :inet.parse_address(String.to_charlist(host)))
  end

  defp html_to_text(bin) do
    bin
    |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
    |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
