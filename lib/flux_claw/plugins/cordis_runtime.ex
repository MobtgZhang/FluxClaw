defmodule FluxClaw.Plugins.CordisRuntime do
  @moduledoc """
  Runs DeepSeek Harness (Cordis) tool plugins in a Node sidecar and exposes
  their tools to the Elixir agent loop.
  """

  use GenServer

  require Logger

  alias FluxClaw.PubSub

  @registry __MODULE__
  @call_timeout 120_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @registry))
  end

  @doc "OpenAI function schemas contributed by loaded Cordis plugins."
  def list_tools do
    if process_alive?(@registry) do
      try do
        GenServer.call(@registry, :list_tools, @call_timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @doc "System-prompt sections registered by plugins."
  def prompt_sections do
    if process_alive?(@registry) do
      try do
        GenServer.call(@registry, :prompt_sections, @call_timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @doc "Execute a registered plugin tool. Returns `{:error, :not_plugin}` when absent."
  def call_tool(name, args, ctx) do
    if process_alive?(@registry) do
      try do
        GenServer.call(@registry, {:call_tool, name, args, ctx}, @call_timeout)
      catch
        :exit, _ -> {:error, :plugin_runtime_unavailable}
      end
    else
      {:error, :plugin_runtime_unavailable}
    end
  end

  @impl true
  def init(opts) do
    config_path = Keyword.get(opts, :config_path) || default_config_path()
    script_path = Keyword.get(opts, :script_path) || script_path()

    configured_node =
      Keyword.get(opts, :node) || Application.get_env(:flux_claw, :plugins, [])[:node] || "node"

    node = System.find_executable(configured_node) || configured_node

    port =
      if File.exists?(config_path) do
        Port.open(
          {:spawn_executable, node},
          [
            :binary,
            :use_stdio,
            cd: Path.dirname(script_path),
            args: ["--import", "tsx/esm", script_path, config_path]
          ]
        )
      end

    state = %{
      port: port,
      config_path: Path.expand(config_path),
      script_path: Path.expand(script_path),
      tools: [],
      prompt_sections: [],
      buffer: "",
      pending: %{},
      request_id: 0,
      ready: false
    }

    Logger.info("Starting Cordis plugin runtime from #{state.config_path}")

    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state), do: {:reply, state.tools, state}

  def handle_call(:prompt_sections, _from, state), do: {:reply, state.prompt_sections, state}

  def handle_call({:call_tool, _name, _args, _ctx}, _from, %{port: nil} = state) do
    {:reply, {:error, :plugin_runtime_unavailable}, state}
  end

  def handle_call({:call_tool, name, args, ctx}, from, state) do
    id = "req-#{state.request_id + 1}"

    payload =
      Jason.encode!(%{
        type: "call_tool",
        id: id,
        name: name,
        args: args,
        sessionId: Map.get(ctx, :session_id),
        sandboxRoot: Map.get(ctx, :sandbox_root),
        cwd: Map.get(ctx, :sandbox_root)
      })

    Port.command(state.port, payload <> "\n")
    state = %{state | request_id: state.request_id + 1, pending: Map.put(state.pending, id, from)}
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Cordis plugin runtime exited: #{status}")

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :plugin_runtime_exited})
    end)

    {:noreply, %{state | pending: %{}, ready: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_message(line, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "tool_registered", "tool" => tool} = msg} ->
        tool = atomize_tool(tool)
        state = put_unless_present(state, :tools, tool)
        broadcast({:plugin_tool_registered, Map.get(msg, "pluginId"), tool.function.name})
        state

      {:ok, %{"type" => "tool_unregistered", "name" => name}} ->
        broadcast({:plugin_tool_unregistered, name})
        update_in(state.tools, &Enum.reject(&1, fn tool -> tool.function.name == name end))

      {:ok, %{"type" => "prompt_section_registered", "section" => section}} ->
        section = atomize_section(section)
        put_unless_present(state, :prompt_sections, section)

      {:ok, %{"type" => "prompt_section_unregistered", "id" => id}} ->
        update_in(
          state.prompt_sections,
          &Enum.reject(&1, fn section -> section[:id] == id end)
        )

      {:ok, %{"type" => "plugin_loaded", "id" => id}} ->
        broadcast({:plugin_loaded, id})
        state

      {:ok, %{"type" => "ready", "tools" => tools}} ->
        Logger.info("Cordis plugin runtime ready with #{length(tools)} plugin tools")
        %{state | ready: true}

      {:ok, %{"type" => "tool_result", "id" => id} = msg} ->
        case Map.get(state.pending, id) do
          nil ->
            state

          from ->
            state = %{state | pending: Map.delete(state.pending, id)}

            if Map.get(msg, "ok") do
              GenServer.reply(from, {:ok, Map.get(msg, "content", "")})
            else
              GenServer.reply(from, {:error, Map.get(msg, "error", "plugin tool failed")})
            end

            state
        end

      {:ok, %{"type" => "error", "message" => message} = msg} ->
        Logger.warning(
          "Cordis plugin error: #{message} #{inspect(Map.delete(msg, "message"), limit: 20)}"
        )

        state

      {:ok, _msg} ->
        state

      {:error, error} ->
        Logger.warning("Could not decode plugin runtime message: #{inspect(error)}")
        state
    end
  end

  defp put_unless_present(state, key, value) do
    already_present? =
      case key do
        :tools -> Enum.any?(state.tools, &(&1.function.name == value.function.name))
        :prompt_sections -> Enum.any?(state.prompt_sections, &(&1[:id] == value[:id]))
      end

    if already_present?, do: state, else: update_in(state, [key], &[value | &1])
  end

  defp split_lines(buffer) do
    [last | rest] =
      buffer
      |> String.split("\n")
      |> Enum.reverse()

    {Enum.reverse(rest), last}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(PubSub, "flux_claw:plugins", msg)

  defp atomize_tool(tool) do
    %{
      type: "function",
      function: %{
        name: tool["name"],
        description: tool["description"] || "",
        parameters: tool["parameters"] || %{"type" => "object", "properties" => %{}}
      }
    }
  end

  defp atomize_section(section) do
    %{
      id: section["id"],
      plugin_id: section["pluginId"],
      title: section["title"] || section["id"],
      content: section["content"],
      priority: section["priority"] || 100
    }
  end

  defp process_alive?(name) do
    case GenServer.whereis(name) do
      nil -> false
      _pid -> true
    end
  end

  defp default_config_path do
    System.get_env("FLUXCLAW_CORDIS_CONFIG") || System.get_env("DSH_CORDIS_CONFIG") ||
      Path.join(File.cwd!(), ".fluxclaw/cordis.yml")
  end

  defp script_path do
    :code.priv_dir(:flux_claw)
    |> to_string()
    |> Path.join("plugins/bridge/index.mjs")
  end
end
