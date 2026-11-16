defmodule FluxClaw.Tools.SandboxTest do
  use ExUnit.Case, async: true

  alias FluxClaw.Tools.Sandbox

  setup do
    tmp = Path.join(System.tmp_dir!(), "flux_claw_sandbox_" <> random_hex())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{root: tmp}
  end

  test "allows paths inside sandbox", %{root: root} do
    assert {:ok, p} = Sandbox.resolve!(root, "a/b.txt")
    assert String.starts_with?(p, Path.expand(root))
  end

  test "rejects path traversal", %{root: root} do
    assert {:error, _} = Sandbox.resolve!(root, "../etc/passwd")
  end

  test "rejects a symlink pointing outside the workspace", %{root: root} do
    File.ln_s!(System.tmp_dir!(), Path.join(root, "escape"))
    assert {:error, _} = Sandbox.resolve!(root, "escape/secret.txt")
    assert {:error, _} = Sandbox.resolve!(root, "escape/new/draft.md")
  end

  defp random_hex do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
