defmodule FluxClaw.Tool do
  @moduledoc "Atomic tool behaviour (GenericAgent-style)."

  @type ctx :: %{
          required(:session_id) => Ecto.UUID.t(),
          required(:sandbox_root) => String.t()
        }

  @type run_result ::
          {:ok, String.t()}
          | {:error, String.t()}
          | {:suspend_ask, pos_integer(), String.t()}
          | {:suspend_review, pos_integer(), map()}
          | {:ok, String.t(), Keyword.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(args :: map(), ctx :: ctx()) :: run_result()

  @modules [
    FluxClaw.Tools.FileRead,
    FluxClaw.Tools.FileWrite,
    FluxClaw.Tools.FilePatch,
    FluxClaw.Tools.ApplyPatch,
    FluxClaw.Tools.ShellExecute,
    FluxClaw.Tools.WebFetch,
    FluxClaw.Tools.AgentSearch,
    FluxClaw.Tools.Harness2,
    FluxClaw.Tools.TaskPlan,
    FluxClaw.Tools.AskUser,
    FluxClaw.Tools.UpdateCheckpoint,
    FluxClaw.Tools.PromoteCheckpoint,
    FluxClaw.Tools.LongTermFact
  ]

  def modules, do: @modules

  def openai_tools do
    builtins =
      Enum.map(@modules, fn m ->
        %{
          type: "function",
          function: %{
            name: m.name(),
            description: m.description(),
            parameters: m.parameters()
          }
        }
      end)

    names = MapSet.new(Enum.map(@modules, & &1.name()))

    builtins ++
      Enum.reject(
        FluxClaw.Plugins.CordisRuntime.list_tools(),
        &MapSet.member?(names, &1.function.name)
      )
  end

  def run(name, args, ctx) when is_binary(name) and is_map(args) do
    case Enum.find(@modules, &(&1.name() == name)) do
      nil -> FluxClaw.Plugins.CordisRuntime.call_tool(name, args, ctx)
      module -> module.run(args, ctx)
    end
  end

  @doc false
  def openai_tools_without_plugins do
    Enum.map(@modules, fn m ->
      %{
        type: "function",
        function: %{
          name: m.name(),
          description: m.description(),
          parameters: m.parameters()
        }
      }
    end)
  end
end
