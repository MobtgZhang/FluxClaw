defmodule FluxClaw.Tools.Diff do
  @moduledoc """
  Minimal unified-diff toolkit for the code-edit / diff-review flow
  (Codex / Claude Code style): generate a unified diff from two texts and
  apply a unified diff onto file contents inside the session sandbox.

  The module is intentionally dependency-free and line-based:

    * `unified_diff/3` — renders the difference between two texts as a
      single hunk with up to 3 leading/trailing context lines
      (common prefix/suffix trimming; adequate for review UIs).
    * `apply_unified/2` — applies a (possibly model-written) unified diff,
      matching each hunk by its removed/context lines near the expected
      offset, tolerating small line drifts. A pure-addition diff (no
      removed/context lines) is treated as new-file content.
    * `diff_lines/1` — splits a diff into tagged lines for display.
  """

  @context 3

  @type diff_line :: {:add | :del | :ctx | :meta, String.t()}

  ## Generation ---------------------------------------------------------------

  @doc "Render a unified diff between `old_text` and `new_text` for `path`."
  @spec unified_diff(String.t() | nil, String.t(), String.t()) :: String.t()
  def unified_diff(old_text, new_text, path) when is_binary(path) do
    old = lines(old_text)
    new = lines(new_text)

    if old == new do
      ""
    else
      {prefix, old_mid, new_mid, suffix} = trim_edges(old, new)

      a_start = length(prefix) + 1
      a_count = max(1, length(prefix) + length(old_mid) + length(suffix))
      b_count = max(1, length(prefix) + length(new_mid) + length(suffix))

      header = "--- a/#{path}\n+++ b/#{path}\n"
      hunk_header = "@@ -#{a_start},#{a_count} +#{a_start},#{b_count} @@\n"

      body =
        Enum.map(prefix, &(" " <> &1)) ++
          Enum.map(old_mid, &("-" <> &1)) ++
          Enum.map(new_mid, &("+" <> &1)) ++
          Enum.map(suffix, &(" " <> &1))

      header <> hunk_header <> Enum.join(body, "\n") <> "\n"
    end
  end

  @doc "Split a unified diff into tagged lines for display in the review UI."
  @spec diff_lines(String.t()) :: [diff_line()]
  def diff_lines(diff_text) when is_binary(diff_text) do
    diff_text
    |> lines()
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "@@") or String.starts_with?(line, "---") or
            String.starts_with?(line, "+++") ->
          {:meta, line}

        String.starts_with?(line, "+") ->
          {:add, strip_prefix(line)}

        String.starts_with?(line, "-") ->
          {:del, strip_prefix(line)}

        true ->
          {:ctx, strip_prefix(line)}
      end
    end)
  end

  defp strip_prefix(""), do: ""
  defp strip_prefix(line), do: String.slice(line, 1..-1//1) || ""

  defp trim_edges(old, new) do
    p = common_prefix_count(old, new)
    s = common_suffix_count(Enum.drop(old, p), Enum.drop(new, p))

    ctx_p = min(p, @context)
    ctx_s = min(s, @context)
    excluded_tail = s - ctx_s

    prefix = Enum.slice(old, p - ctx_p, ctx_p)
    suffix = Enum.slice(old, length(old) - ctx_s, ctx_s)

    old_body = Enum.slice(old, p, max(0, length(old) - p - excluded_tail))
    new_body = Enum.slice(new, p, max(0, length(new) - p - excluded_tail))

    old_mid = Enum.slice(old_body, 0, max(0, length(old_body) - ctx_s))
    new_mid = Enum.slice(new_body, 0, max(0, length(new_body) - ctx_s))

    {prefix, old_mid, new_mid, suffix}
  end

  defp common_prefix_count([x | a], [x | b]), do: 1 + common_prefix_count(a, b)
  defp common_prefix_count(_, _), do: 0

  defp common_suffix_count(a, b), do: common_suffix_count(Enum.reverse(a), Enum.reverse(b), 0)

  defp common_suffix_count([x | a], [x | b], n), do: common_suffix_count(a, b, n + 1)
  defp common_suffix_count(_, _, n), do: n

  defp lines(nil), do: []

  defp lines(s) when is_binary(s) do
    s
    |> String.split(["\r\n", "\n"])
    |> Enum.reverse()
    |> drop_trailing_empty()
    |> Enum.reverse()
  end

  defp drop_trailing_empty(["" | rest]), do: drop_trailing_empty(rest)
  defp drop_trailing_empty(list), do: list

  ## Applying -----------------------------------------------------------------

  @doc """
  Apply a unified diff to `original`. Returns `{:ok, new_text}` or
  `{:error, reason}`.
  """
  @spec apply_unified(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_unified(diff, original) when is_binary(diff) and is_binary(original) do
    case parse_hunks(lines(diff)) do
      {:ok, []} ->
        {:error, "no hunks found in diff"}

      {:ok, hunks} ->
        apply_hunks(hunks, lines(original))

      {:error, _} = err ->
        err
    end
  end

  defp parse_hunks(diff_lines), do: do_parse_hunks(diff_lines, [])

  defp do_parse_hunks([], acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse_hunks([line | rest], acc) do
    cond do
      String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
        do_parse_hunks(rest, acc)

      String.starts_with?(line, "@@") ->
        expected = expected_offset(line)

        case take_hunk_body(rest, []) do
          {body, rest2} when is_list(body) -> do_parse_hunks(rest2, [{expected, body} | acc])
          {:error, _} = err -> err
        end

      hunk_body_line?(line) ->
        {body, rest2} = take_hunk_body([line | rest], [])
        do_parse_hunks(rest2, [{0, body} | acc])

      line == "" ->
        do_parse_hunks(rest, acc)

      true ->
        {:error, "unexpected diff line: " <> inspect(String.slice(line, 0, 40))}
    end
  end

  defp expected_offset(line) do
    case Regex.run(~r/^@@ -(\d+)/, line) do
      [_, s] ->
        case Integer.parse(s) do
          {n, _} -> max(0, n - 1)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp hunk_body_line?(line) do
    line == "" or String.starts_with?(line, " ") or String.starts_with?(line, "+") or
      String.starts_with?(line, "-")
  end

  defp take_hunk_body(rest, acc) do
    case rest do
      [line | r] ->
        if hunk_body_line?(line) do
          take_hunk_body(r, [line | acc])
        else
          {Enum.reverse(acc), rest}
        end

      [] ->
        {Enum.reverse(acc), []}
    end
  end

  defp apply_hunks([], lines), do: {:ok, join_lines(lines)}

  defp apply_hunks([{expected, body} | rest], lines) do
    removed =
      body
      |> Enum.filter(&(String.starts_with?(&1, "-") or String.starts_with?(&1, " ")))
      |> Enum.map(&strip_prefix/1)

    # Context (" ") and added ("+") lines are what survives the hunk, in order.
    kept =
      body
      |> Enum.filter(&(String.starts_with?(&1, " ") or String.starts_with?(&1, "+")))
      |> Enum.map(&strip_prefix/1)

    cond do
      removed == [] and kept == [] ->
        apply_hunks(rest, lines)

      removed == [] and lines == [] ->
        # Pure-addition diff on an empty/absent file: new-file content.
        apply_hunks(rest, kept)

      removed == [] ->
        # Pure addition on existing content: append at the tail (lenient).
        apply_hunks(rest, lines ++ kept)

      true ->
        case find_anchor(lines, removed, expected) do
          nil ->
            {:error, "could not find hunk anchor in file"}

          index ->
            head = Enum.slice(lines, 0, index)
            tail = Enum.drop(lines, index + length(removed))
            apply_hunks(rest, head ++ kept ++ tail)
        end
    end
  end

  defp find_anchor(lines, needle, expected) do
    n = length(lines)
    k = length(needle)

    if k <= n do
      positions =
        Enum.to_list(0..(n - k))
        |> Enum.sort_by(&abs(&1 - expected))

      Enum.find(positions, fn i ->
        Enum.slice(lines, i, k) == needle
      end)
    end
  end

  defp join_lines([]), do: ""
  defp join_lines(lines), do: Enum.join(lines, "\n") <> "\n"
end
