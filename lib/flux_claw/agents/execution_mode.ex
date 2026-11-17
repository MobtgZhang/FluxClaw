defmodule FluxClaw.Agents.ExecutionMode do
  @moduledoc "Execution policy shared by tool discovery and the tool dispatch boundary."

  @planning_tools ~w(file_read web_fetch agent_search task_plan ask_user)

  def allowed?("agent", _name), do: true
  def allowed?("plan", name), do: name in @planning_tools
  def allowed?(_, _name), do: false

  def instructions("plan") do
    "当前为规划模式。读取资料、检索信息、澄清需求，并使用 task_plan 整理可执行步骤。" <>
      "不得修改文件、运行终端命令、调用插件或保存长期记忆。完成后说明方案与待确认事项，" <>
      "请用户切换到执行模式并发送指令后再实施。不要声称已经完成实施。"
  end

  def instructions(_), do: "当前为执行模式。根据用户要求使用工具完成任务，并核实结果。"
end
