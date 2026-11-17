defmodule FluxClaw.Test.ModelRequestPlug do
  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    send(Application.fetch_env!(:flux_claw, :llm_capture_owner), {:http_payload, payload})

    if payload["stream"] do
      data = %{"choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]}

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: " <> Jason.encode!(data) <> "\n\ndata: [DONE]\n\n")
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}]
        })
      )
    end
  end
end
