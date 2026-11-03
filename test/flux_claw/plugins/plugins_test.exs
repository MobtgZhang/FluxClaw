defmodule FluxClaw.PluginsTest do
  use ExUnit.Case, async: false

  alias FluxClaw.Plugins
  alias FluxClaw.Plugins.CordisConfig

  setup do
    tmp = Path.join(System.tmp_dir!(), "flux_claw_plugins_" <> random_hex())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    prev = System.get_env("FLUXCLAW_CORDIS_CONFIG")
    System.put_env("FLUXCLAW_CORDIS_CONFIG", Path.join(tmp, "cordis.yml"))

    on_exit(fn ->
      if prev do
        System.put_env("FLUXCLAW_CORDIS_CONFIG", prev)
      else
        System.delete_env("FLUXCLAW_CORDIS_CONFIG")
      end
    end)

    %{tmp: tmp, config: Path.join(tmp, "cordis.yml")}
  end

  describe "CordisConfig.parse/1" do
    test "parses the shape of .fluxclaw/cordis.example.yml" do
      text = """
      # Copy this file to .fluxclaw/cordis.yml to load DeepSeek Harness plugins.
      #
      # Official npm plugin example:
      - id: tool-todo
        name: '@deepseek-ai/dsh-tool-todo'
        config:
          allowParallelInProgress: false
          maxItems: 3

      # Local plugin example:
      - id: local-greet
        name: '/absolute/path/to/my-plugin.js'
        config:
          greeting: 'Hello'
      """

      assert [todo, greet] = CordisConfig.parse(text)

      assert todo["id"] == "tool-todo"
      assert todo["name"] == "@deepseek-ai/dsh-tool-todo"
      assert todo["config"]["allowParallelInProgress"] == false
      assert todo["config"]["maxItems"] == 3

      assert greet["id"] == "local-greet"
      assert greet["name"] == "/absolute/path/to/my-plugin.js"
      assert greet["config"]["greeting"] == "Hello"
    end

    test "comments-only or empty documents parse to an empty list" do
      assert CordisConfig.parse("# just a comment\n") == []
      assert CordisConfig.parse("") == []
    end

    test "parses booleans, integers and bare scalars" do
      text = """
      - id: a
        enabled: true
        retries: 5
        label: hello world
      """

      assert [%{"id" => "a", "enabled" => true, "retries" => 5, "label" => "hello world"}] =
               CordisConfig.parse(text)
    end
  end

  describe "CordisConfig.read_plugins/1" do
    test "returns :enoent for a missing file" do
      assert {:error, :enoent} =
               CordisConfig.read_plugins(Path.join(System.tmp_dir!(), "nope.yml"))
    end

    test "reads a configured file", %{config: config} do
      File.write!(config, "- id: tool-a\n  name: '@x/y'\n")
      assert {:ok, [%{"id" => "tool-a", "name" => "@x/y"}]} = CordisConfig.read_plugins()
    end
  end

  describe "Plugins.summary/0" do
    test "reports a missing config", %{config: config} do
      File.rm(config)
      summary = Plugins.summary()

      assert summary.config_path == config
      assert summary.config_found == false
      assert is_boolean(summary.runtime_running)
      assert is_boolean(summary.runtime_ready)
      assert summary.plugins == []
    end

    test "merges configured plugins with runtime state", %{config: config} do
      File.write!(config, "- id: tool-todo\n  name: '@deepseek-ai/dsh-tool-todo'\n")

      summary = Plugins.summary()

      assert summary.config_found == true

      assert [%{id: "tool-todo", name: "@deepseek-ai/dsh-tool-todo", source_kind: :npm} = p] =
               summary.plugins

      # The runtime is not started in this test, so nothing is loaded.
      assert p.loaded == false
      assert p.tools == []
    end

    test "classifies local plugin sources", %{config: config} do
      File.write!(config, "- id: local-greet\n  name: /tmp/some-plugin.js\n")

      assert [%{id: "local-greet", source_kind: :local}] = Plugins.summary().plugins
    end
  end

  defp random_hex do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
