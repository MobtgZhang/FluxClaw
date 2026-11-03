defmodule FluxClaw.Tools.FileWrite do
  @behaviour FluxClaw.Tool

  alias FluxClaw.Tools.{Review, Sandbox}

  @impl true
  def name, do: "file_write"

  @impl true
  def description do
    "Write UTF-8 text to a file under the sandbox (creates parent dirs). " <>
      "When diff review is enabled the change is proposed to the user and only written after they keep it."
  end

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
  def run(%{"path" => rel, "content" => content}, ctx)
      when is_binary(rel) and is_binary(content) do
    case Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        abs |> Path.dirname() |> File.mkdir_p!()
        old = optional_read(abs)
        Review.propose_write(ctx, rel, abs, old, content, name())

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing path or content"}

  defp optional_read(abs) do
    case File.read(abs) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end
end
