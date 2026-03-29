defmodule FluxClaw.Tools.FileRead do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "file_read"

  @impl true
  def description, do: "Read a UTF-8 text file under the session sandbox."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Relative path inside sandbox"}
      },
      required: ["path"]
    }
  end

  @impl true
  def run(%{"path" => rel}, ctx) do
    case FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing path"}
end
