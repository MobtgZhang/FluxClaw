defmodule FluxClawWeb.MarkdownTest do
  use ExUnit.Case, async: true
  alias FluxClawWeb.Markdown

  test "model HTML cannot add scripts, event handlers or unsafe links" do
    html =
      Markdown.render("""
      <script>alert(1)</script>

      <img src="https://example.com/a.png" onerror="alert(1)">

      [quoted](https://example.com "\" onmouseover=\"alert(1)")

      <a href="java&#x73;cript:alert(1)" phx-click="delete_session">unsafe</a>

      [unsafe](javascript:alert%281%29)

      <iframe src="/">frame</iframe>
      """)

    doc = LazyHTML.from_fragment("<div>" <> html <> "</div>")

    assert LazyHTML.query(doc, "script, iframe, [onerror], [onmouseover], [phx-click]")
           |> Enum.empty?()

    assert LazyHTML.query(doc, "a[href^='javascript:']") |> Enum.empty?()
    assert LazyHTML.query(doc, "img[src='https://example.com/a.png']") |> Enum.count() == 1
  end

  test "ordinary Markdown retains code, links and tables" do
    html =
      Markdown.render("""
      [Source](https://example.com)

      ```html
      <script>alert(1)</script>
      ```

      | Name | Result |
      |---|---|
      | Task | Complete |
      """)

    doc = LazyHTML.from_fragment("<div>" <> html <> "</div>")
    assert LazyHTML.query(doc, "a[href='https://example.com']") |> Enum.count() == 1
    assert LazyHTML.query(doc, "pre code") |> Enum.count() == 1
    assert LazyHTML.query(doc, "script") |> Enum.empty?()
    assert LazyHTML.query(doc, "table tbody tr") |> Enum.count() == 1
  end
end
