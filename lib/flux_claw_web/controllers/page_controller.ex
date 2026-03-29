defmodule FluxClawWeb.PageController do
  use FluxClawWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
