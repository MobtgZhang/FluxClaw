defmodule FluxClaw.ConfigLoaderTest do
  use ExUnit.Case, async: false

  defp temp_config_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "flux_claw_cfg_#{suffix}_#{System.unique_integer([:positive])}.json"
    )
  end

  test "reads nested openai and sandbox_root from JSON file" do
    path = temp_config_path("nested")

    json = ~S"""
    {
      "openai": { "api_key": "sk-test", "base_url": "https://example.com/v1", "model": "m1" },
      "sandbox_root": "/tmp/sbox"
    }
    """

    File.write!(path, json)
    System.put_env("FLUX_CLAW_CONFIG_PATH", path)

    on_exit(fn ->
      System.delete_env("FLUX_CLAW_CONFIG_PATH")
      File.rm(path)
    end)

    cfg = FluxClaw.ConfigLoader.load()

    assert cfg.openai_api_key == "sk-test"
    assert cfg.openai_base_url == "https://example.com/v1"
    assert cfg.openai_model == "m1"
    assert cfg.flux_claw_sandbox == "/tmp/sbox"
  end

  test "flat keys and flux_claw_sandbox alias" do
    path = temp_config_path("flat")

    File.write!(path, ~S"""
    {
      "openai_api_key": "sk-flat",
      "openai_model": "m2",
      "flux_claw_sandbox": "/x"
    }
    """)

    System.put_env("FLUX_CLAW_CONFIG_PATH", path)

    on_exit(fn ->
      System.delete_env("FLUX_CLAW_CONFIG_PATH")
      File.rm(path)
    end)

    cfg = FluxClaw.ConfigLoader.load()
    assert cfg.openai_api_key == "sk-flat"
    assert cfg.openai_model == "m2"
    assert cfg.flux_claw_sandbox == "/x"
    refute Map.has_key?(cfg, :openai_base_url)
  end
end
