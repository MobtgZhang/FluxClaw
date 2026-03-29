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
          | {:ok, String.t(), Keyword.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(args :: map(), ctx :: ctx()) :: run_result()

  @modules [
    FluxClaw.Tools.FileRead,
    FluxClaw.Tools.FileWrite,
    FluxClaw.Tools.FilePatch,
    FluxClaw.Tools.AskUser,
    FluxClaw.Tools.UpdateCheckpoint,
    FluxClaw.Tools.LongTermFact
  ]

  def modules, do: @modules

  def openai_tools do
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

  def run(name, args, ctx) when is_binary(name) and is_map(args) do
    mod = Enum.find(@modules, &(&1.name() == name))
    if mod, do: mod.run(args, ctx), else: {:error, "unknown tool #{name}"}
  end
end
