defmodule FluxClaw.Tools.Sandbox do
  @moduledoc false
  def resolve!(sandbox_root, relative) when is_binary(sandbox_root) and is_binary(relative) do
    base = Path.expand(sandbox_root)
    joined = Path.expand(relative, base)

    cond do
      String.contains?(relative, <<0>>) ->
        {:error, "invalid path"}

      joined != base and not String.starts_with?(joined, String.trim_trailing(base, "/") <> "/") ->
        {:error, "path escapes sandbox"}

      symlink_component?(joined) ->
        {:error, "symbolic links are not allowed in sandbox paths"}

      true ->
        File.mkdir_p!(base)
        {:ok, joined}
    end
  end

  defp symlink_component?(path) do
    Path.split(path)
    |> tl()
    |> Enum.reduce_while(path |> Path.split() |> hd(), fn part, acc ->
      next = Path.join(acc, part)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> {:halt, true}
        _ -> {:cont, next}
      end
    end) == true
  end
end
