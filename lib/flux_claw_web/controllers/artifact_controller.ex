defmodule FluxClawWeb.ArtifactController do
  use FluxClawWeb, :controller

  def show(conn, %{"session_id" => sid, "path" => segments} = params) do
    with {:ok, _} <- Ecto.UUID.cast(sid),
         %{} <- FluxClaw.Agents.get_session(sid),
         {:ok, path} <-
           FluxClaw.Tools.Sandbox.resolve!(FluxClaw.Artifacts.root(sid), Path.join(segments)),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= 20_000_000 do
      text? =
        Path.extname(path) in [
          ".md",
          ".txt",
          ".json",
          ".csv",
          ".ex",
          ".exs",
          ".py",
          ".js",
          ".css",
          ".log",
          ".yml",
          ".yaml"
        ] and size <= 512_000

      conn =
        conn
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("x-content-type-options", "nosniff")

      send_download(conn, {:file, path},
        filename: Path.basename(path),
        content_type:
          if(text?, do: "text/plain; charset=utf-8", else: "application/octet-stream"),
        disposition: if(text? and params["download"] != "1", do: :inline, else: :attachment)
      )
    else
      _ -> send_resp(conn, 404, "File unavailable")
    end
  end
end
