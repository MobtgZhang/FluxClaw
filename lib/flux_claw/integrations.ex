defmodule FluxClaw.Integrations do
  @moduledoc "Server-owned settings for native AgentSearch and Harness² tools."
  def config do
    raw = FluxClaw.ConfigLoader.load_raw()["integrations"] || %{}

    %{
      search_url: System.get_env("AGENT_SEARCH_URL") || raw["search_url"] || "",
      search_mode: System.get_env("AGENT_SEARCH_MODE") || raw["search_mode"] || "local",
      search_key: System.get_env("AGENT_SEARCH_API_KEY") || raw["search_key"] || "",
      python:
        System.get_env("FLUXCLAW_PYTHON") || raw["python"] || System.find_executable("python3") ||
          ""
    }
  end

  def request_options, do: Application.get_env(:flux_claw, :integration_req_options, [])
end
