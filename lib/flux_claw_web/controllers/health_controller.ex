defmodule FluxClawWeb.HealthController do
  use FluxClawWeb, :controller
  def show(conn, _), do: json(conn, %{status: "ok", app: "fluxclaw"})
end
