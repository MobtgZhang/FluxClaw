defmodule FluxClaw.Tools.FileWrite do
  @behaviour FluxClaw.Tool

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write UTF-8 text to a file under the sandbox (creates parent dirs)."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        content: %{type: "string"}
      },
      required: ["path", "content"]
    }
  end

  @impl true
  def run(%{"path" => rel, "content" => content}, ctx) do
    case FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        abs |> Path.dirname() |> File.mkdir_p!()

        case File.write(abs, content) do
          :ok -> {:ok, "wrote #{byte_size(content)} bytes"}
          {:error, r} -> {:error, inspect(r)}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing path or content"}
end
