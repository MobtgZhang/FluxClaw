defmodule FluxClaw.Plugins.CordisRuntimeTest do
  use ExUnit.Case, async: false

  @moduletag :deepseek_plugins

  test "loads a local Cordis tool plugin and executes it through the bridge" do
    unique = System.unique_integer([:positive])
    config_path = Path.join(System.tmp_dir!(), "flux_claw_cordis_#{unique}.yml")
    plugin_path = Path.join(System.tmp_dir!(), "flux_claw_plugin_#{unique}.mjs")

    File.write!(plugin_path, """
    export const name = 'test-plugin'
    export const inject = ['tools']

    export function apply(ctx, config) {
      ctx.tools.register({
        name: 'test_echo',
        description: 'Echoes its arguments for the test suite.',
        parameters: { type: 'object', properties: {}, required: [] },
        output: {
          schema: { type: 'string' },
          render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
          return `${config.prefix}:${JSON.stringify(args)}`
        },
      })
    }
    """)

    File.write!(config_path, """
    - id: test-plugin
      name: #{plugin_path}
      config:
        prefix: echo
    """)

    name = :"flux_claw_cordis_runtime_#{unique}"
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, "flux_claw:plugins")

    start_supervised!({FluxClaw.Plugins.CordisRuntime, config_path: config_path, name: name})
    assert_receive {:plugin_loaded, "test-plugin"}, 10_000

    tools = GenServer.call(name, :list_tools, 10_000)
    assert [%{function: %{name: "test_echo"}}] = tools

    assert {:ok, ~s(echo:{"value":1})} =
             GenServer.call(name, {:call_tool, "test_echo", %{"value" => 1}, %{}}, 10_000)

    on_exit(fn ->
      File.rm(plugin_path)
      File.rm(config_path)
    end)
  after
    Phoenix.PubSub.unsubscribe(FluxClaw.PubSub, "flux_claw:plugins")
  end
end
