defmodule FluxClawWeb.Markdown do
  @moduledoc "Renders untrusted model text with a small, inert Markdown HTML surface."
  @tags ~w(p br hr h1 h2 h3 h4 h5 h6 blockquote pre code em strong del s ul ol li a img table thead tbody tr th td span)

  def render(text) when is_binary(text) and text != "" do
    Earmark.as_html!(text,
      gfm: true,
      breaks: true,
      ignore_strings: true,
      postprocessor: &sanitize_node/1
    )
  rescue
    _ -> escape(text)
  end

  def render(_), do: ""

  defp sanitize_node({tag, attrs, children, _meta}) when tag in @tags do
    attrs =
      attrs
      |> Enum.filter(&safe_attribute?(tag, &1))
      |> Enum.map(fn {name, value} -> {name, Plug.HTML.html_escape(value)} end)

    {tag, attrs, children, %{}}
  end

  defp sanitize_node(_), do: {:replace, ""}

  defp safe_attribute?("a", {"href", value}), do: safe_url?(value, true)
  defp safe_attribute?("img", {"src", value}), do: safe_url?(value, false)

  defp safe_attribute?(tag, {attr, _}) when tag in ["a", "img"] and attr in ["title", "alt"],
    do: true

  defp safe_attribute?("code", {"class", value}),
    do: Regex.match?(~r/\A[a-zA-Z0-9_+ .-]{1,100}\z/, value)

  defp safe_attribute?("ol", {"start", value}), do: Regex.match?(~r/\A[0-9]{1,9}\z/, value)
  defp safe_attribute?(_, _), do: false

  defp safe_url?(value, mail?) when is_binary(value) do
    not Regex.match?(~r/[\x00-\x20\x7f\\]/, value) and
      cond do
        String.starts_with?(value, ["/", "#"]) -> true
        URI.parse(value).scheme in ["http", "https"] -> true
        mail? and URI.parse(value).scheme == "mailto" -> true
        true -> false
      end
  end

  defp safe_url?(_, _), do: false
  defp escape(text), do: Plug.HTML.html_escape(text)
end
