defmodule FluxClawWeb.RedirectController do
  use FluxClawWeb, :controller

  def to_chat(conn, _params), do: redirect(conn, to: ~p"/")

  def agents_to_chat(conn, %{"id" => id}), do: redirect(conn, to: ~p"/chat/#{id}")
end
