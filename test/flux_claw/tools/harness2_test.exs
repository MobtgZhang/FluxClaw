defmodule FluxClaw.Tools.Harness2Test do
  use ExUnit.Case, async: false
  alias FluxClaw.Tools.Harness2

  test "budgets and operation are validated before launching" do
    assert {:error, _} = Harness2.run(%{"operation" => "shell"}, %{})
    assert {:error, _} = Harness2.run(%{"task" => "x", "k" => 10}, %{})
    assert {:error, _} = Harness2.run(%{"task" => ""}, %{})
  end

  @tag :harness2_runtime
  test "upstream accounting demo executes through native tool dispatch" do
    root = Path.join(System.tmp_dir!(), "fluxclaw-h2-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, json} =
             FluxClaw.Tool.run(
               "harness2_optimize",
               %{"operation" => "demo", "k" => 1, "mode" => "sequential"},
               %{sandbox_root: root, session_id: Ecto.UUID.generate()}
             )

    data = Jason.decode!(json)
    assert data["report"]["done"] == 2
    assert data["report"]["failed"] == 0
    assert data["answer"] =~ "85.15"
    assert data["answer"] =~ "20.25"
    assert File.regular?(Path.join(root, data["artifact"]))
    assert Path.wildcard(Path.join(root, "harness2/library/**/EXPERIENCE.md")) != []
  end
end
