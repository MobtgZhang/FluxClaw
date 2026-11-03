defmodule FluxClaw.Tools.ApplyPatch do
  @moduledoc false
  @behaviour FluxClaw.Tool

  alias FluxClaw.Tools.{Diff, Review, Sandbox}

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description do
    "Apply a unified diff to a file under the sandbox (creates the file when the diff is pure additions). " <>
      "The resulting change is proposed to the user as a diff and only written after they keep it."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Relative path inside the sandbox"},
        diff: %{type: "string", description: "Unified diff (@@ hunks) to apply"},
        description: %{type: "string", description: "Optional one-line intent of the change"}
      },
      required: ["path", "diff"]
    }
  end

  @impl true
  def run(%{"path" => rel, "diff" => diff} = args, ctx)
      when is_binary(rel) and is_binary(diff) do
    description = Map.get(args, "description")

    case Sandbox.resolve!(ctx.sandbox_root, rel) do
      {:ok, abs} ->
        old = read_optional(abs)

        case Diff.apply_unified(diff, old || "") do
          {:ok, new} ->
            propose(rel, abs, old, new, description, ctx)

          {:error, reason} ->
            {:error, "patch failed: " <> reason}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing path or diff"}

  defp read_optional(abs) do
    case File.read(abs) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end

  defp propose(rel, abs, old, new, description, ctx) do
    case Review.propose_write(ctx, rel, abs, old, new, name()) do
      {:ok, msg} -> {:ok, maybe_with_intent(msg, description)}
      {:error, _} = err -> err
      {:suspend_review, ref, payload} -> {:suspend_review, ref, payload}
    end
  end

  defp maybe_with_intent(msg, nil), do: msg
  defp maybe_with_intent(msg, description), do: msg <> " — " <> description
end
