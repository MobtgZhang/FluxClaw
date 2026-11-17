defmodule FluxClaw.Artifacts do
  @moduledoc "Bounded, symlink-free browsing of real session sandbox files."
  alias FluxClaw.Tools.Sandbox

  def root(session_id),
    do: Path.join(Application.fetch_env!(:flux_claw, :agents)[:sandbox_root], session_id)

  def list(session_id) do
    root = root(session_id)
    walk(root, "", 0, []) |> Enum.take(150) |> Enum.sort_by(& &1.path)
  rescue
    File.Error -> []
  end

  defp walk(_root, _relative, depth, acc) when depth > 8 or length(acc) >= 150, do: acc

  defp walk(root, relative, depth, acc) do
    with {:ok, abs} <- Sandbox.resolve!(root, relative), {:ok, names} <- File.ls(abs) do
      Enum.reduce_while(Enum.sort(names), acc, fn name, files ->
        path = Path.join(relative, name)

        result =
          case File.lstat(Path.join(abs, name)) do
            {:ok, %{type: :regular, size: size}} ->
              [
                %{
                  id: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower),
                  path: path,
                  size: size
                }
                | files
              ]

            {:ok, %{type: :directory}} ->
              walk(root, path, depth + 1, files)

            _ ->
              files
          end

        if length(result) >= 150, do: {:halt, result}, else: {:cont, result}
      end)
    else
      _ -> acc
    end
  end
end
