defmodule FluxClaw.Agents.AgentWorkerTest do
  use FluxClaw.DataCase, async: false

  alias FluxClaw.Agents
  alias FluxClaw.Agents.AgentWorker
  alias FluxClaw.Agents.Orchestrator

  test "mock LLM completes and broadcasts assistant" do
    {:ok, session} = Agents.create_session(%{title: "t"})
    topic = "agent:" <> session.id
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, topic)

    _agent_pid = start_supervised!({AgentWorker, session_id: session.id})

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

  test "stopping an interrupted tool closes the protocol and prevents refresh resume" do
    {:ok, session} = Agents.create_session(%{title: "cancel"})
    {:ok, _} = Agents.append_message(session.id, %{role: "user", content: "read files"})

    call = %{
      "id" => "cancelled-call",
      "type" => "function",
      "function" => %{"name" => "file_read", "arguments" => "{}"}
    }

    {:ok, _} =
      Agents.append_message(session.id, %{
        role: "assistant",
        content: "",
        metadata: %{"tool_calls" => [call]}
      })

    assert {:ok, _} = Agents.record_stop(session.id, "Partial answer")
    refute AgentWorker.needs_resume?(session.id)
    messages = Agents.list_messages(session.id)

    assert Enum.any?(
             messages,
             &(&1.role == "tool" and &1.metadata["call_id"] == "cancelled-call")
           )

    assert List.last(messages).content == "Partial answer"
  end

  test "worker shutdown terminates an active linked model request" do
    owner = self()
    old = Application.get_env(:flux_claw, :llm_mock_reply)

    Application.put_env(:flux_claw, :llm_mock_reply, fn _ ->
      send(owner, {:model_running, self()})

      receive do
        :finish -> %{content: "done", tool_calls: []}
      end
    end)

    on_exit(fn ->
      if old,
        do: Application.put_env(:flux_claw, :llm_mock_reply, old),
        else: Application.delete_env(:flux_claw, :llm_mock_reply)
    end)

    {:ok, session} = Agents.create_session(%{title: "stop"})
    pid = start_supervised!({AgentWorker, session_id: session.id})
    GenServer.cast(pid, {:user_message, "work"})
    assert_receive {:model_running, task}
    ref = Process.monitor(task)
    :ok = stop_supervised({AgentWorker, session.id})
    assert_receive {:DOWN, ^ref, :process, ^task, reason}
    assert reason in [:killed, :shutdown]
  end
end
