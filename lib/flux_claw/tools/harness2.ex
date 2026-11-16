defmodule FluxClaw.Tools.Harness2 do
  @moduledoc "Runs the actual vendored Harness² recursion through a bounded text-only adapter."
  @behaviour FluxClaw.Tool
  def name, do: "harness2_optimize"

  def description,
    do:
      "Use Google's Harness² recursive refinement, blind selection and reusable experience library to improve a written deliverable with the current model. Runs multiple model calls (max 30), not arbitrary code. operation=demo runs the upstream deterministic accounting check without a model. Requires Python 3.12/3.13. Results and report are saved in the session sandbox."

  def parameters do
    %{
      type: "object",
      properties: %{
        task: %{type: "string"},
        operation: %{type: "string", enum: ["optimize", "demo"]},
        mode: %{type: "string", enum: ["parallel", "sequential"]},
        k: %{type: "integer", minimum: 1, maximum: 2}
      },
      additionalProperties: false
    }
  end

  def run(args, ctx) do
    operation = args["operation"] || "optimize"
    mode = args["mode"] || "parallel"
    k = args["k"] || 1
    task = args["task"] || ""
    python = FluxClaw.Integrations.config().python

    cond do
      operation not in ["optimize", "demo"] or mode not in ["parallel", "sequential"] or
          k not in [1, 2] ->
        {:error, "invalid Harness² operation/mode/k"}

      not is_binary(task) or byte_size(task) > 16000 or
          (operation == "optimize" and String.trim(task) == "") ->
        {:error, "task must contain 1–16000 bytes"}

      python == "" or not File.regular?(python) ->
        {:error, "请在工具集成中配置 Python 3.12/3.13 可执行文件"}

      true ->
        execute(python, %{operation: operation, task: task, mode: mode, k: k}, ctx)
    end
  rescue
    _ -> {:error, "Harness² could not start; check Python configuration and sandbox permissions"}
  end

  defp execute(python, request, ctx) do
    relative = "harness2/" <> Ecto.UUID.generate()

    with {:ok, output} <- FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, relative),
         {:ok, library} <-
           FluxClaw.Tools.Sandbox.resolve!(ctx.sandbox_root, "harness2/library/k#{request.k}") do
      script = Application.app_dir(:flux_claw, "priv/integrations/harness2_runner.py")

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          {:line, 1_000_000},
          {:args, ["-I", script]},
          {:env, private_environment()}
        ])

      try do
        Port.command(
          port,
          Jason.encode!(Map.merge(request, %{output: output, library: library})) <> "\n"
        )

        deadline = System.monotonic_time(:millisecond) + 300_000

        case receive_output(port, deadline, 0, "") do
          {:ok, result} ->
            {:ok,
             Jason.encode!(%{
               answer: result["answer"],
               report: result["report"],
               artifact: relative <> "/report.json",
               directory: relative
             })}

          {:error, reason} ->
            {:error, "#{reason}. Artifacts: #{relative}"}
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  end

  defp receive_output(port, deadline, calls, partial) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        if byte_size(partial) + byte_size(chunk) > 1_000_000,
          do: {:error, "Harness² output exceeded limit"},
          else: receive_output(port, deadline, calls, partial <> chunk)

      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(partial <> line) do
          {:ok, %{"type" => "result"} = result} ->
            {:ok, result}

          {:ok, %{"type" => "error", "error" => error}} ->
            {:error, error}

          {:ok, %{"type" => "llm", "system" => system, "user" => user}}
          when is_binary(system) and is_binary(user) ->
            if calls >= 30 or remaining <= 0 or byte_size(system) + byte_size(user) > 1_000_000 do
              {:error, "Harness² model budget exceeded"}
            else
              module = Application.get_env(:flux_claw, :llm)[:llm_module] || FluxClaw.LLM.OpenAI

              task =
                Task.async(fn ->
                  module.complete(
                    [%{role: "system", content: system}, %{role: "user", content: user}],
                    [],
                    timeout: min(remaining, 90_000),
                    retry: false
                  )
                end)

              reply =
                case Task.yield(task, min(remaining, 90_000)) || Task.shutdown(task, :brutal_kill) do
                  {:ok, {:ok, %{content: text}}} when is_binary(text) ->
                    %{content: String.slice(text, 0, 60000)}

                  _ ->
                    %{error: "Model request failed; check FluxClaw model settings"}
                end

              Port.command(port, Jason.encode!(reply) <> "\n")
              receive_output(port, deadline, calls + 1, "")
            end

          _ ->
            receive_output(port, deadline, calls, "")
        end

      {^port, {:exit_status, code}} ->
        {:error, "Harness² exited #{code}; Python 3.12/3.13 is required"}
    after
      remaining -> {:error, "Harness² exceeded the 300 second deadline"}
    end
  end

  defp private_environment do
    System.get_env()
    |> Enum.filter(fn {key, _} ->
      Regex.match?(~r/(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)/i, key)
    end)
    |> Enum.map(fn {key, _} -> {String.to_charlist(key), false} end)
  end
end
