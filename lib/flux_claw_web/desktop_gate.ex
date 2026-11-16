defmodule FluxClawWeb.DesktopGate do
  @moduledoc "Restricts the desktop loopback backend to its owning Electron session."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    case System.get_env("FLUXCLAW_DESKTOP_TOKEN") do
      token when is_binary(token) and byte_size(token) >= 32 ->
        case get_req_header(conn, "x-fluxclaw-desktop") do
          [provided] when byte_size(provided) == byte_size(token) ->
            if Plug.Crypto.secure_compare(provided, token), do: conn, else: reject(conn)

          _ ->
            reject(conn)
        end

      _ ->
        conn
    end
  end

  defp reject(conn), do: conn |> send_resp(403, "Desktop session required") |> halt()
end
