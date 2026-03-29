defmodule FluxClaw.Tools.FilePatch do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "file_patch"

  @impl true
  def description, do: "Replace first occurrence of `find` with `replace` in a sandbox file."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        find: %{type: "string"},
        replace: %{type: "string"}
      },
      required: ["path", "find", "replace"]
    }
  end

  @impl true
  def run(%{"path" => rel, "find" => find, "replace" => replace}, ctx) do
    case FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, data} ->
            if String.contains?(data, find) do
              new = String.replace(data, find, replace, global: false)

              case File.write(abs, new) do
                :ok -> {:ok, "patched"}
                {:error, r} -> {:error, inspect(r)}
              end
            else
              {:error, "find string not found"}
            end

          {:error, r} ->
            {:error, inspect(r)}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing fields"}
end
