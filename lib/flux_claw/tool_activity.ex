defmodule FluxClaw.ToolActivity do
  @moduledoc "Pairs persisted and live tool events by call ID. Legacy entries remain independent."

  def rows(events) do
    Enum.reduce(events, [], fn
      {:tool_start, id, name, args}, rows ->
        rows ++ [row(id, name, args, nil)]

      {:tool_start, name, args}, rows ->
        rows ++ [row(nil, name, args, nil)]

      {:tool_done, id, name, text}, rows ->
        case Enum.find_index(rows, &(&1.id == id && &1.state == :running)) do
          nil -> rows ++ [row(id, name, nil, text)]
          index -> List.update_at(rows, index, &row(id, name, &1.args, text))
        end

      _, rows ->
        rows
    end)
  end

  defp row(id, name, args, output) do
    state =
      cond do
        is_nil(output) -> :running
        String.starts_with?(String.downcase(output), ["error:", "error "]) -> :error
        true -> :done
      end

    label =
      if is_map(args),
        do: Enum.find_value(["path", "url", "query", "task", "command"], &args[&1]),
        else: nil

    %{id: id, name: name, args: args, output: output, state: state, label: label || ""}
  end
end
