defmodule FluxClaw.ConfigLoader do
  @moduledoc false

  @doc """
  Canonical **write** path: `fluxclaw/cache/config.json` (unless `FLUXCLAW_CONFIG_PATH` is set).

  **Read** merges `.fluxclaw/config.json` (base) with this file (overrides).
  """
  def config_write_path do
    Path.join(File.cwd!(), "fluxclaw/cache/config.json")
  end

  defp config_path_env do
    System.get_env("FLUXCLAW_CONFIG_PATH") || System.get_env("FLUX_CLAW_CONFIG_PATH")
  end

  def config_path do
    config_path_env() || config_write_path()
  end

  @doc "Default cache root directory (relative to cwd unless expanded)."
  def default_cache_root do
    Path.join(File.cwd!(), "fluxclaw/cache")
  end

  @doc """
  Loads merged JSON config (see `load_raw/0`) into a flat keyword map for runtime.

  Supports nested `"openai"`, `"cache_paths"`, `"agents"` (see `.fluxclaw/config.example.json`).
  """
  def load do
    case load_raw() do
      data when data == %{} -> %{}
      data -> coerce(data)
    end
  end

  defp coerce(data) when is_map(data) do
    flat = stringify_map(data)
    openai = stringify_map(Map.get(flat, "openai") || %{})
    cache = stringify_map(Map.get(flat, "cache_paths") || %{})
    agents = stringify_map(Map.get(flat, "agents") || %{})

    %{
      openai_api_key: pick([flat["openai_api_key"], openai["api_key"]]),
      openai_base_url: pick([flat["openai_base_url"], openai["base_url"]]),
      openai_model: pick([flat["openai_model"], openai["model"]]),
      openai_temperature: parse_float_field(openai["temperature"]),
      openai_top_p: parse_float_field(openai["top_p"]),
      openai_top_k: parse_int_field(openai["top_k"]),
      flux_claw_sandbox: pick([flat["flux_claw_sandbox"], flat["sandbox_root"]]),
      cache_root: pick([cache["cache_root"], flat["cache_root"]]),
      cache_external_skills: pick([cache["external_skills"], flat["external_skills_path"]]),
      cache_internal_skills: pick([cache["internal_skills"], flat["internal_skills_path"]]),
      cache_history_root: pick([cache["history_root"], flat["history_root"]]),
      cache_memory_root: pick([cache["memory_root"], flat["memory_root"]]),
      agents_max_steps: parse_int_field(agents["max_steps"] || flat["agents_max_steps"]),
      agents_self_evolve: parse_bool_field(agents["self_evolve"]),
      agents_crystallize_skills: parse_bool_field(agents["crystallize_skills"]),
      agents_crystallize_mode: parse_crystallize_mode(agents["crystallize_mode"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Reads merged JSON config as a map with string keys.

  If `FLUXCLAW_CONFIG_PATH` is set, only that file is read (same variable name as write target).
  Otherwise merges `.fluxclaw/config.json` then `fluxclaw/cache/config.json` (later wins).
  """
  def load_raw do
    case config_path_env() do
      p when is_binary(p) and p != "" ->
        read_json_file(Path.expand(p))

      _ ->
        cwd = File.cwd!()
        dot = Path.join(cwd, ".fluxclaw/config.json")
        cache = config_write_path()
        base = read_json_file(dot)
        over = read_json_file(cache)
        deep_merge(base, over)
    end
  end

  defp read_json_file(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, data} when is_map(data) -> data
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Deep-merge `updates` (string-key maps) into the existing JSON file and persist.
  """
  def merge_save!(updates) when is_map(updates) do
    merged = deep_merge(load_raw(), stringify_map(updates))
    path = config_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(merged, pretty: true))
    merged
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn
      _, va, vb when is_map(va) and is_map(vb) -> deep_merge(va, vb)
      _, _, vb -> vb
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp parse_int_field(nil), do: nil

  defp parse_int_field(n) when is_integer(n), do: n

  defp parse_int_field(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int_field(_), do: nil

  defp parse_bool_field(nil), do: nil

  defp parse_bool_field(true), do: true
  defp parse_bool_field(false), do: false

  defp parse_bool_field(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> nil
    end
  end

  defp parse_bool_field(_), do: nil

  defp parse_crystallize_mode(nil), do: nil

  defp parse_crystallize_mode(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      "confirm" -> :confirm
      "auto" -> :auto
      _ -> nil
    end
  end

  defp parse_crystallize_mode(a) when is_atom(a), do: a
  defp parse_crystallize_mode(_), do: nil

  defp parse_float_field(nil), do: nil

  defp parse_float_field(n) when is_float(n), do: n

  defp parse_float_field(n) when is_integer(n), do: n * 1.0

  defp parse_float_field(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float_field(_), do: nil

  defp pick(values) do
    Enum.find_value(values, fn
      v when is_binary(v) ->
        if String.trim(v) != "", do: v

      _ ->
        nil
    end)
  end
end
