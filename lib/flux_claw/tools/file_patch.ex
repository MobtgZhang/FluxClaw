defmodule FluxClaw.Tools.FilePatch do
  @behaviour FluxClaw.Tool

  alias FluxClaw.Tools.{Review, Sandbox}

  @impl true
  def name, do: "file_patch"

  @impl true
  def description do
    "Replace the first occurrence of `find` with `replace` in a sandbox file. " <>
      "When diff review is enabled the change is proposed to the user and only written after they keep it."
  end

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
  def run(%{"path" => rel, "find" => find, "replace" => replace}, ctx)
      when is_binary(rel) and is_binary(find) and is_binary(replace) do
    case Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, data} ->
            if String.contains?(data, find) do
              new = String.replace(data, find, replace, global: false)
              Review.propose_write(ctx, rel, abs, data, new, name())
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
