defmodule FluxClaw.Tools.ShellExecute do
  @moduledoc false
  @behaviour FluxClaw.Tool
  @max_out 65_536

  @impl true
  def name, do: "shell_execute"

  @impl true
  def description do
    "Run a shell command with cwd restricted to the session sandbox. " <>
      "Unix uses /bin/sh -c; Windows uses cmd /c. Output is truncated."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        command: %{type: "string", description: "Shell command to run"},
        cwd: %{type: "string", description: "Working directory relative to sandbox (default .)"},
        timeout_ms: %{type: "integer", description: "Timeout in ms (default 15000, max 60000)"}
      },
      required: ["command"]
    }
  end

  @impl true
  def run(%{"command" => cmd} = args, ctx) when is_binary(cmd) do
    cwd_rel = Map.get(args, "cwd", ".")
    timeout_ms = Map.get(args, "timeout_ms", 15_000)
    timeout_ms = timeout_ms |> min(60_000) |> max(1_000)

    case FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, cwd_rel) do
      {:ok, cwd} ->
        run_with_timeout(cmd, cwd, timeout_ms)

      {:error, msg} ->
        {:error, msg}
    end
  end

  def run(_, _), do: {:error, "missing command"}

  defp run_with_timeout(cmd, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        case :os.type() do
          {:win32, _} ->
            System.cmd("cmd", ["/c", cmd],
              cd: cwd,
              stderr_to_stdout: true,
              env: []
            )

          _ ->
            System.cmd("/bin/sh", ["-c", cmd],
              cd: cwd,
              stderr_to_stdout: true,
              env: []
            )
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit}} ->
        out = output |> String.slice(0, @max_out)
        {:ok, "exit=#{exit}\n#{out}"}

      nil ->
        {:error, "command timed out"}

      {:exit, reason} ->
        {:error, "command failed: #{inspect(reason)}"}
    end
  end
end
