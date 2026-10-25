defmodule Mix.Tasks.Plugins.Setup do
  @moduledoc "Installs the DeepSeek Harness Cordis bridge runtime."

  @shortdoc "Installs DeepSeek Harness plugin bridge dependencies"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    bridge = Path.join(File.cwd!(), "priv/plugins/bridge")

    if File.dir?(bridge) do
      Mix.shell().cmd("npm install --prefix #{bridge}",
        env: [{"NPM_CONFIG_FUND", "false"}, {"NPM_CONFIG_AUDIT", "false"}]
      )
    else
      Mix.raise("Missing DeepSeek Harness bridge at priv/plugins/bridge")
    end
  end
end
