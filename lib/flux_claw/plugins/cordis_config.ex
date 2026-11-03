defmodule FluxClaw.Plugins.CordisConfig do
  @moduledoc """
  Minimal YAML-subset reader for the Cordis plugin configuration
  (`.fluxclaw/cordis.yml`), same file the DeepSeek Harness bridge consumes.

  Supported subset: top-level sequence of mappings, nested mappings one or
  more levels deep, scalars (strings incl. quotes, booleans, integers) and
  full-line `#` comments. Anything more exotic is out of scope on purpose —
  the bridge (Node) owns the full YAML.
  """

  @type entry :: %{optional(String.t()) => term()}

  @doc "Config file path, mirroring the bridge lookup order."
  def config_path do
    System.get_env("FLUXCLAW_CORDIS_CONFIG") || System.get_env("DSH_CORDIS_CONFIG") ||
      Path.join(File.cwd!(), ".fluxclaw/cordis.yml")
  end

  @doc "Parse the plugin list. Returns `{:error, :enoent}` when not configured."
  @spec read_plugins(String.t() | nil) ::
          {:ok, [entry()]} | {:error, :enoent | {:parse, String.t()}}
  def read_plugins(path \\ config_path())

  def read_plugins(nil), do: read_plugins(config_path())

  def read_plugins(path) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, parse(text)}
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "Parse a cordis.yml document (YAML subset) into a list of plugin entries."
  @spec parse(String.t()) :: [entry()]
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&rstrip_comment/1)
      |> Enum.filter(&(String.trim(&1) != ""))
      |> Enum.map(fn line ->
        indent = line |> String.to_charlist() |> Enum.take_while(&(&1 == ?\s)) |> length()
        {indent, String.trim(line)}
      end)

    case lines do
      [] ->
        []

      [{i, "- " <> _} | _] ->
        {items, _rest} = parse_list(lines, i, [])
        items

      _ ->
        []
    end
  end

  defp rstrip_comment(line) do
    cond do
      Regex.match?(~r/^\s*#/, line) -> ""
      true -> line
    end
  end

  defp parse_list([{i, "- " <> rest} | tail], i, acc) do
    {item, rest_lines} =
      cond do
        key_value_entry?(rest) ->
          {first_map, rest2} = parse_inline_first_entry(rest, i, tail)
          {first_map, rest2}

        true ->
          {scalar(rest), tail}
      end

    parse_list(rest_lines, i, acc ++ [item])
  end

  defp parse_list(lines, _i, acc), do: {acc, lines}

  defp key_value_entry?(rest) do
    case split_key(rest) do
      {key, _value} -> key != ""
      :error -> false
    end
  end

  # `- id: x` plus following deeper-indented lines form one mapping item.
  defp parse_inline_first_entry(rest, i, tail) do
    {key, value} = split_key(rest)
    children = take_deeper(tail, i)

    case children do
      [_ | _] ->
        ci = child_indent(tail, i)
        {map, _} = parse_map(children, ci, %{})

        map =
          if value == "" do
            map
          else
            Map.put_new(map, key, scalar(value))
          end

        {map, Enum.drop(tail, length(children))}

      _ ->
        {%{key => (value == "" && %{}) || scalar(value)}, tail}
    end
  end

  # Lines deeper-indented than the list item belong to that item's mapping;
  # the next sibling entry (indent <= i) ends the mapping.
  defp take_deeper(lines, i), do: Enum.take_while(lines, fn {ind, _} -> ind > i end)

  defp child_indent([{ind, _} | _], _i), do: ind
  defp child_indent([], i), do: i + 2

  defp parse_map([{i, line} | tail], i, acc) do
    case split_key(line) do
      {key, value} when key != "" ->
        if value == "" do
          {children, rest} = Enum.split_while(tail, fn {ind, _} -> ind > i end)

          nested =
            case children do
              [] -> %{}
              [{ci, _} | _] -> parse_map(children, ci, %{}) |> elem(0)
            end

          parse_map(rest, i, Map.put(acc, key, nested))
        else
          parse_map(tail, i, Map.put(acc, key, scalar(value)))
        end

      :error ->
        parse_map(tail, i, acc)
    end
  end

  defp parse_map(_lines, _i, acc), do: {acc, []}

  defp split_key(line) do
    case String.split(line, ":", parts: 2) do
      [key] -> {strip_quotes(key), ""}
      [key, value] -> {strip_quotes(key), String.trim(value)}
      _ -> :error
    end
  end

  defp scalar(value) do
    v = strip_quotes(value)

    cond do
      v in ["true", "True", "yes"] ->
        true

      v in ["false", "False", "no"] ->
        false

      Regex.match?(~r/^-?\d+$/, v) ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> v
        end

      true ->
        v
    end
  end

  defp strip_quotes(v) do
    v = String.trim(v)

    if String.length(v) >= 2 and String.starts_with?(v, ["'", "\""]) and
         String.last(v) == String.first(v) do
      String.slice(v, 1..-2//1)
    else
      v
    end
  end
end
