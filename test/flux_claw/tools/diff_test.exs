defmodule FluxClaw.Tools.DiffTest do
  use ExUnit.Case, async: true

  alias FluxClaw.Tools.Diff

  @old_text """
  defmodule Demo do
    def one do
      1
    end

    def two do
      2
    end
  end
  """

  test "unified_diff returns empty string for identical content" do
    assert Diff.unified_diff(@old_text, @old_text, "demo.ex") == ""
  end

  test "unified_diff renders header and hunk with context" do
    new_text = String.replace(@old_text, "1", "42")

    diff = Diff.unified_diff(@old_text, new_text, "demo.ex")

    assert diff =~ "--- a/demo.ex"
    assert diff =~ "+++ b/demo.ex"
    assert diff =~ "@@ -"
    assert diff =~ "-    1\n"
    assert diff =~ "+    42\n"
    assert diff =~ " defmodule Demo do\n"
  end

  test "diff_lines tags add/del/meta/context lines" do
    lines = Diff.diff_lines("--- a/x.ex\n+++ b/x.ex\n@@ -1,3 +1,3 @@\n ctx\n-del\n+add\n")

    assert lines == [
             {:meta, "--- a/x.ex"},
             {:meta, "+++ b/x.ex"},
             {:meta, "@@ -1,3 +1,3 @@"},
             {:ctx, "ctx"},
             {:del, "del"},
             {:add, "add"}
           ]
  end

  test "roundtrip: apply_unified recreates the new content" do
    new_text = String.replace(@old_text, "def two", "def three")

    diff = Diff.unified_diff(@old_text, new_text, "demo.ex")
    assert {:ok, ^new_text} = Diff.apply_unified(diff, @old_text)
  end

  test "apply_unified tolerates anchor drift from the expected offset" do
    filler = Enum.map(1..40, &"line #{&1}\n") |> Enum.join()
    original = filler <> "alpha\nbeta\n"
    diff = "--- a/f.txt\n+++ b/f.txt\n@@ -2,2 +2,2 @@\n alpha\n-beta\n+gamma\n"

    # The hunk header claims line 2 but the anchor lives at line 41.
    assert {:ok, result} = Diff.apply_unified(diff, original)
    assert result == filler <> "alpha\ngamma\n"
  end

  test "apply_unified treats a pure-addition diff as new-file content" do
    diff = "--- a/new.txt\n+++ b/new.txt\n@@ -0,1 +0,1 @@\n+brand new\n"

    assert {:ok, "brand new\n"} = Diff.apply_unified(diff, "")
    assert {:ok, "old\nbrand new\n"} = Diff.apply_unified(diff, "old\n")
  end

  test "apply_unified fails cleanly on a missing anchor" do
    diff = "--- a/x.txt\n+++ b/x.txt\n@@ -1,1 +1,1 @@\n-missing line\n+ok\n"

    assert {:error, "could not find hunk anchor in file"} = Diff.apply_unified(diff, "other\n")
  end
end
