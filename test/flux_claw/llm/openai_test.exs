defmodule FluxClaw.LLM.OpenAITest do
  use ExUnit.Case, async: false
  alias FluxClaw.LLM.OpenAI

  setup do
    old = Application.get_env(:flux_claw, :llm)

    server =
      start_supervised!(
        {Bandit, plug: FluxClaw.Test.ModelRequestPlug, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:flux_claw, :llm_capture_owner, self())

    Application.put_env(:flux_claw, :llm,
      api_key: "test",
      base_url: "http://127.0.0.1:#{port}/v1",
      model: "default",
      temperature: 0.7,
      top_p: 0.9
    )

    on_exit(fn ->
      Application.put_env(:flux_claw, :llm, old)
      Application.delete_env(:flux_claw, :llm_capture_owner)
    end)

    :ok
  end

  test "streaming and non-streaming forward selected model and reasoning without incompatible sampling" do
    opts = [model: "o3", reasoning_effort: "high"]
    assert {:ok, _} = OpenAI.complete([%{role: "user", content: "hi"}], [], opts)
    assert_receive {:http_payload, payload}
    assert payload["model"] == "o3"
    assert payload["reasoning_effort"] == "high"
    refute Map.has_key?(payload, "temperature")
    refute Map.has_key?(payload, "top_p")
    assert {:ok, _} = OpenAI.stream([%{role: "user", content: "hi"}], [], opts, fn _ -> :ok end)
    assert_receive {:http_payload, streamed}
    assert streamed["stream"]
    assert streamed["model"] == "o3"
    assert streamed["reasoning_effort"] == "high"
  end

  test "automatic reasoning omits effort and retains ordinary model sampling" do
    opts = FluxClaw.LLM.RunSettings.options(%{model: "gpt-4.1", reasoning_effort: "auto"})
    assert {:ok, _} = OpenAI.complete([], [], opts)
    assert_receive {:http_payload, payload}
    refute Map.has_key?(payload, "reasoning_effort")
    assert payload["temperature"] == 0.7
    assert payload["top_p"] == 0.9
  end
end
