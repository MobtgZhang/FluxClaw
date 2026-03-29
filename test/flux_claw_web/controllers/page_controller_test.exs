defmodule FluxClawWeb.PageControllerTest do
  use FluxClawWeb.ConnCase

  test "GET / renders chat shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "FluxClaw"
  end
end
