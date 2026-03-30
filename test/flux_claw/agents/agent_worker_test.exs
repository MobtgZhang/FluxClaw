defmodule FluxClaw.Agents.AgentWorkerTest do
  use FluxClaw.DataCase, async: false

  alias FluxClaw.Agents
  alias FluxClaw.Agents.AgentWorker
  alias FluxClaw.Agents.Orchestrator

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(FluxClaw.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(FluxClaw.Repo, {:shared, self()})
    :ok
  end

  test "mock LLM completes and broadcasts assistant" do
    {:ok, session} = Agents.create_session(%{title: "t"})
    topic = "agent:" <> session.id
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, topic)

    {:ok, agent_pid} = Orchestrator.ensure_worker(session.id)
    Ecto.Adapters.SQL.Sandbox.allow(FluxClaw.Repo, self(), agent_pid)

    assert :ok = Orchestrator.send_message(session.id, "hi")

    assert_receive {:user, "hi", _}
    assert_receive {:assistant_delta, _}
    assert_receive {:assistant_done, "mock ok", _}
  end

  test "needs_resume? is false when last message is assistant with empty metadata (no stack overflow)" do
    {:ok, session} = Agents.create_session(%{title: "t"})
    {:ok, _} = Agents.append_message(session.id, %{role: "user", content: "q"})

    {:ok, _} =
      Agents.append_message(session.id, %{
        role: "assistant",
        content: "final",
        metadata: %{}
      })

    refute AgentWorker.needs_resume?(session.id)
  end
end
