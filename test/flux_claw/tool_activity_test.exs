defmodule FluxClaw.ToolActivityTest do
  use ExUnit.Case, async: true
  alias FluxClaw.ToolActivity

  test "same-name concurrent calls pair by id, independent of completion order" do
    rows =
      ToolActivity.rows([
        {:tool_start, "a", "file_read", %{"path" => "a"}},
        {:tool_start, "b", "file_read", %{"path" => "b"}},
        {:tool_done, "b", "file_read", "error: missing"},
        {:tool_done, "a", "file_read", "hello"}
      ])

    assert [
             %{id: "a", label: "a", state: :done, output: "hello"},
             %{id: "b", label: "b", state: :error}
           ] = rows
  end

  test "legacy starts stay independent of unmatched results" do
    assert [%{id: nil, state: :running}, %{id: "x", state: :done}] =
             ToolActivity.rows([{:tool_start, "read", %{}}, {:tool_done, "x", "read", "ok"}])
  end
end
