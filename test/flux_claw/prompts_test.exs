defmodule FluxClaw.PromptsTest do
  use ExUnit.Case, async: true

  test "CoWork prompt loads the office workflow and substitutes runtime context" do
    prompt =
      FluxClaw.Prompts.render_system(%{
        session_id: "test-task",
        project_id: "test-project",
        sandbox_root: "/tmp/work"
      })

    assert prompt =~ "task_plan"
    assert prompt =~ "数据分析"
    assert prompt =~ "附件"
    assert prompt =~ "Session: test-task"
    refute prompt =~ "{{"
  end
end
