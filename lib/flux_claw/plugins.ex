defmodule FluxClaw.Plugins do
  @moduledoc """
  Plugin registry for the plugin-manager UI: merges the configured plugins
  (`.fluxclaw/cordis.yml`, read by `FluxClaw.Plugins.CordisConfig`) with the
  live state of the Cordis bridge runtime (`FluxClaw.Plugins.CordisRuntime`).
  """

  alias FluxClaw.Plugins.{CordisConfig, CordisRuntime}

  @type plugin_info :: %{
          id: String.t(),
          name: String.t() | nil,
          source_kind: :npm | :local,
          config: map(),
          loaded: boolean(),
          tools: [String.t()]
        }

  @type summary :: %{
          config_path: String.t(),
          config_found: boolean(),
          runtime_running: boolean(),
          runtime_ready: boolean(),
          plugins: [plugin_info()],
          tools: [map()],
          prompt_sections: [map()]
        }

  @doc "Snapshot for the plugin panel."
  @spec summary() :: summary()
  def summary do
    runtime = runtime_snapshot()
    config = CordisConfig.read_plugins()

    configured =
      case config do
        {:ok, entries} -> Enum.map(entries, &describe(&1, runtime))
        _ -> []
      end

    loaded_extra =
      runtime
      |> Map.get(:plugins, [])
      |> Enum.reject(fn id -> Enum.any?(configured, &(&1.id == id)) end)
      |> Enum.map(fn id -> describe(%{"id" => id}, runtime) end)

    %{
      config_path: CordisConfig.config_path(),
      config_found: match?({:ok, _}, config),
      runtime_running: Map.get(runtime, :running) == true,
      runtime_ready: Map.get(runtime, :ready) == true,
      plugins: configured ++ loaded_extra,
      tools: Map.get(runtime, :tools, []),
      prompt_sections: Map.get(runtime, :prompt_sections, [])
    }
  end

  defp runtime_snapshot do
    case CordisRuntime.status() do
      %{} = status -> status
      {:error, _} -> %{}
    end
  end

  defp describe(%{} = entry, runtime) do
    id = to_string(Map.get(entry, "id") || Map.get(entry, "name") || "")
    name = Map.get(entry, "name") || Map.get(entry, "id")
    kind = source_kind(name)

    %{
      id: id,
      name: name,
      source_kind: kind,
      config: Map.get(entry, "config") || %{},
      loaded: id != "" and id in Map.get(runtime, :plugins, []),
      tools:
        runtime
        |> Map.get(:tools_by_plugin, %{})
        |> Map.get(id, [])
        |> Enum.reverse()
    }
  end

  defp source_kind(name) when is_binary(name) do
    if String.starts_with?(name, ["/", "./", "../", ".\\"]) or name =~ ~r/^[A-Za-z]:(\\|\/)/ do
      :local
    else
      :npm
    end
  end

  defp source_kind(_), do: :npm
end
