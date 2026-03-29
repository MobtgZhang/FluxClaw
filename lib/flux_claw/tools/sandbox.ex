defmodule FluxClaw.Tools.Sandbox do
  @moduledoc false

  def resolve!(sandbox_root, relative) when is_binary(sandbox_root) and is_binary(relative) do
    base = Path.expand(sandbox_root)
    File.mkdir_p!(base)
    joined = Path.expand(relative, base)

    if safe_path?(base, joined) do
      {:ok, joined}
    else
      {:error, "path escapes sandbox"}
    end
  end

  defp safe_path?(base, path) do
    base = String.trim_trailing(base, "/")
    path = Path.expand(path)
    path == base or String.starts_with?(path, base <> "/")
  end
end
