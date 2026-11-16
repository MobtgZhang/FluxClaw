defmodule FluxClaw.Tools.AgentSearchTest do
  use ExUnit.Case, async: false
  alias FluxClaw.Tools.AgentSearch

  setup do
    vars =
      for key <- ["AGENT_SEARCH_URL", "AGENT_SEARCH_MODE", "AGENT_SEARCH_API_KEY"],
          into: %{},
          do: {key, System.get_env(key)}

    System.put_env("AGENT_SEARCH_URL", "http://search.test")
    System.put_env("AGENT_SEARCH_MODE", "local")
    System.put_env("AGENT_SEARCH_API_KEY", "search-secret")
    old = Application.get_env(:flux_claw, :integration_req_options)
    Application.put_env(:flux_claw, :integration_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(vars, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

      if old,
        do: Application.put_env(:flux_claw, :integration_req_options, old),
        else: Application.delete_env(:flux_claw, :integration_req_options)
    end)

    :ok
  end

  test "local contract yields bounded citations" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "query" => "Phoenix",
               "limit_final_pagerank_results" => 2,
               "limit_broad_results" => 1000
             } = Jason.decode!(body)

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer search-secret"]
      assert conn.request_path == "/search"

      Req.Test.json(conn, %{
        results: [
          %{
            title: "Docs",
            url: "https://phoenixframework.org",
            text: String.duplicate("a", 7000)
          },
          %{title: nil},
          %{title: "extra"}
        ]
      })
    end)

    assert {:ok, output} = AgentSearch.run(%{"query" => "Phoenix", "limit" => 2}, %{})
    assert %{"count" => 2, "sources" => [first, second]} = Jason.decode!(output)
    assert first["citation"] == "[1]"
    assert String.length(first["text"]) == 6000
    assert second["title"] == ""
  end

  test "hosted mode uses provider and top-level results" do
    System.put_env("AGENT_SEARCH_MODE", "sciphi")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"provider" => "agent-search", "query" => "q"} == Jason.decode!(body)
      Req.Test.json(conn, [%{text: "answer"}])
    end)

    assert {:ok, _} = AgentSearch.run(%{"query" => "q"}, %{})
  end

  test "errors do not expose credentials or invent results" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{secret: "search-secret"})
    end)

    assert {:error, error} = AgentSearch.run(%{"query" => "q"}, %{})
    refute error =~ "search-secret"
    assert {:error, _} = AgentSearch.run(%{"query" => "q", "limit" => 100}, %{})
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
    assert {:error, _} = AgentSearch.run(%{"query" => "q"}, %{})
  end
end
