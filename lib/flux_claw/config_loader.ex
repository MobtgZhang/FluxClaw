defmodule FluxClaw.ConfigLoader do
  @moduledoc false

  @doc """
  Path to the local JSON config file.

  Override with environment variable `FLUX_CLAW_CONFIG_PATH` (absolute or relative path).
  Default: `.fluxclaw/config.json` under `File.cwd!/0` (usually the project root when using `mix phx.server`).
  """
  def config_path do
    System.get_env("FLUX_CLAW_CONFIG_PATH") ||
      Path.join(File.cwd!(), ".fluxclaw/config.json")
  end

  @doc """
  Loads `.fluxclaw/config.json` if present. Invalid JSON or missing file yields `%{}`.

  Supports flat keys and a nested `"openai"` object (see `.fluxclaw/config.example.json`).
  """
  def load do
    path = config_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, data} when is_map(data) -> coerce(data)
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  end

  defp coerce(data) when is_map(data) do
    flat = stringify_map(data)
    openai = stringify_map(Map.get(flat, "openai") || %{})

    %{
      openai_api_key: pick([flat["openai_api_key"], openai["api_key"]]),
      openai_base_url: pick([flat["openai_base_url"], openai["base_url"]]),
      openai_model: pick([flat["openai_model"], openai["model"]]),
      flux_claw_sandbox: pick([flat["flux_claw_sandbox"], flat["sandbox_root"]])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp pick(values) do
    Enum.find_value(values, fn
      v when is_binary(v) ->
        if String.trim(v) != "", do: v

      _ ->
        nil
    end)
  end
end
