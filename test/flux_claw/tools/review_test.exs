defmodule FluxClaw.Tools.ReviewTest do
  use ExUnit.Case, async: false

  alias FluxClaw.Tools.{ApplyPatch, FilePatch, FileWrite, Review}

  @old_text "hello\nworld\n"

  setup do
    tmp = Path.join(System.tmp_dir!(), "flux_claw_review_" <> random_hex())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    prev = Application.get_env(:flux_claw, :agents, [])
    on_exit(fn -> Application.put_env(:flux_claw, :agents, prev) end)

    %{root: tmp}
  end

  test "enabled? defaults to true" do
    Application.put_env(:flux_claw, :agents, [])
    assert Review.enabled?()
  end

  test "enabled? honours review_edits: false" do
    Application.put_env(:flux_claw, :agents, review_edits: false)
    refute Review.enabled?()
  end

  test "propose_write returns :ok without touching disk when content is identical", %{root: root} do
    abs = Path.join(root, "same.txt")
    File.write!(abs, @old_text)

    assert {:ok, "no changes (content identical)"} =
             Review.propose_write(ctx(root), "same.txt", abs, @old_text, @old_text, "file_write")

    assert File.read!(abs) == @old_text
  end

  test "propose_write suspends with a review payload and does not write", %{root: root} do
    Application.put_env(:flux_claw, :agents, review_edits: true)

    abs = Path.join(root, "draft.txt")
    new_text = "hello\nthere\n"

    assert {:suspend_review, ref, payload} =
             Review.propose_write(ctx(root), "draft.txt", abs, @old_text, new_text, "file_write")

    assert is_integer(ref) and ref > 0
    assert payload["tool"] == "file_write"
    assert payload["path"] == "draft.txt"
    assert payload["abs_path"] == abs
    assert payload["new_content"] == new_text
    assert payload["diff"] =~ "-world\n+there\n"
    refute File.exists?(abs)

    # Keeping the proposal writes the file.
    assert {:ok, "kept: wrote " <> _} = Review.apply_kept(payload)
    assert File.read!(abs) == new_text
  end

  test "propose_write writes directly when review is disabled", %{root: root} do
    Application.put_env(:flux_claw, :agents, review_edits: false)

    abs = Path.join(root, "direct.txt")

    assert {:ok, "wrote " <> _} =
             Review.propose_write(ctx(root), "direct.txt", abs, @old_text, "hi\n", "file_write")

    assert File.read!(abs) == "hi\n"
  end

  test "file_write proposes a diff review by default", %{root: root} do
    assert {:suspend_review, _ref, %{"tool" => "file_write"} = payload} =
             FileWrite.run(%{"path" => "a.txt", "content" => "one\n"}, ctx(root))

    assert payload["path"] == "a.txt"
    refute File.exists?(Path.join(root, "a.txt"))
  end

  test "file_patch proposes a diff review on replacement", %{root: root} do
    File.write!(Path.join(root, "b.txt"), @old_text)

    assert {:suspend_review, _ref, %{"tool" => "file_patch"} = payload} =
             FilePatch.run(
               %{"path" => "b.txt", "find" => "world", "replace" => "flux"},
               ctx(root)
             )

    assert payload["new_content"] == "hello\nflux\n"
    assert File.read!(Path.join(root, "b.txt")) == @old_text
  end

  test "file_patch errors when find string is missing", %{root: root} do
    File.write!(Path.join(root, "c.txt"), @old_text)

    assert {:error, "find string not found"} =
             FilePatch.run(%{"path" => "c.txt", "find" => "nope", "replace" => "x"}, ctx(root))
  end

  test "apply_patch proposes a diff review and honours keep", %{root: root} do
    File.write!(Path.join(root, "d.txt"), @old_text)
    diff = "--- a/d.txt\n+++ b/d.txt\n@@ -1,2 +1,2 @@\n-hello\n+HELLO\n world\n"

    assert {:suspend_review, _ref, %{"tool" => "apply_patch"} = payload} =
             ApplyPatch.run(%{"path" => "d.txt", "diff" => diff}, ctx(root))

    assert payload["new_content"] == "HELLO\nworld\n"
    assert {:ok, _} = Review.apply_kept(payload)
    assert File.read!(Path.join(root, "d.txt")) == "HELLO\nworld\n"
  end

  test "apply_patch errors on an unapplicable diff", %{root: root} do
    diff = "--- a/e.txt\n+++ b/e.txt\n@@ -1,1 +1,1 @@\n-absent\n+x\n"

    assert {:error, "patch failed: could not find hunk anchor in file"} =
             ApplyPatch.run(%{"path" => "e.txt", "diff" => diff}, ctx(root))
  end

  defp ctx(root) do
    %{session_id: "test-session", sandbox_root: root}
  end

  defp random_hex do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
