defmodule FluxClawWeb.ArtifactControllerTest do
  use FluxClawWeb.ConnCase, async: false

  setup do
    {:ok, session} = FluxClaw.Agents.create_session(%{title: "artifacts"})
    root = FluxClaw.Artifacts.root(session.id)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "answer.md"), "# result")
    File.write!(Path.join(root, "page.html"), "<script>alert(1)</script>")
    on_exit(fn -> File.rm_rf!(root) end)
    %{sid: session.id, root: root}
  end

  test "previews real text safely and offers downloads", %{conn: conn, sid: sid} do
    conn = get(conn, "/artifacts/#{sid}/answer.md")
    assert response(conn, 200) == "# result"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "inline"
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    conn = get(build_conn(), "/artifacts/#{sid}/page.html")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/octet-stream"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
  end

  test "symlinks and unknown sessions cannot expose files", %{conn: conn, sid: sid, root: root} do
    File.ln_s!("/etc/passwd", Path.join(root, "secret"))
    assert get(conn, "/artifacts/#{sid}/secret") |> response(404)
    assert get(build_conn(), "/artifacts/#{Ecto.UUID.generate()}/answer.md") |> response(404)
  end
end
