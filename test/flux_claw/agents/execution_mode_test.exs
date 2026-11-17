defmodule FluxClaw.Agents.ExecutionModeTest do
  use FluxClaw.DataCase, async: false

  alias FluxClaw.Agents
  alias FluxClaw.Agents.AgentWorker
  alias FluxClaw.Tool

  test "planning advertises only allowed tools and fails closed for unknown modes" do
    names = Tool.openai_tools("plan") |> Enum.map(& &1.function.name)
    assert Enum.sort(names) == ~w(agent_search ask_user file_read task_plan web_fetch)
    assert Tool.openai_tools("unknown") == []
    assert Enum.any?(Tool.openai_tools("agent"), &(&1.function.name == "file_write"))
  end

  test "planning blocks writes, patches, shell, memory changes and plugins at dispatch" do
    root = Path.join(System.tmp_dir!(), "planning-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "notes.txt"), "original")
    on_exit(fn -> File.rm_rf!(root) end)
    ctx = %{session_id: Ecto.UUID.generate(), sandbox_root: root, execution_mode: "plan"}

    for name <-
          ~w(file_write file_patch apply_patch shell_execute update_checkpoint promote_checkpoint long_term_fact harness2_optimize plugin_side_effect) do
      assert {:error, message} =
               Tool.run(name, %{"path" => "notes.txt", "content" => "changed"}, ctx)

      assert message =~ "规划模式不允许"
    end

    assert File.read!(Path.join(root, "notes.txt")) == "original"
    assert {:ok, content} = Tool.run("file_read", %{"path" => "notes.txt"}, ctx)
    assert content =~ "original"
  end

  test "worker rejects a model's unadvertised write and reloads mode next turn" do
    owner = self()
    old_llm = Application.fetch_env!(:flux_claw, :llm)
    old_reply = Application.get_env(:flux_claw, :llm_mock_reply)
    old_agents = Application.fetch_env!(:flux_claw, :agents)
    old_paths = Application.get_env(:flux_claw, :cache_paths, [])
    memory_root = Path.join(System.tmp_dir!(), "planning-memory-#{Ecto.UUID.generate()}")

    Application.put_env(
      :flux_claw,
      :agents,
      Keyword.merge(old_agents, self_evolve: true, crystallize_skills: true)
    )

    Application.put_env(
      :flux_claw,
      :cache_paths,
      Keyword.put(old_paths, :memory_root, memory_root)
    )

    Application.put_env(:flux_claw, :llm, llm_module: FluxClaw.LLM.Mock, model: "mock")

    Application.put_env(:flux_claw, :llm_mock_reply, fn messages ->
      send(owner, {:mode_prompt, hd(messages)["content"]})

      if Enum.any?(messages, &(&1["role"] == "tool")) do
        %{content: "finished", tool_calls: []}
      else
        %{
          content: "",
          tool_calls: [
            %{
              "id" => "denied-write",
              "function" => %{
                "name" => "file_write",
                "arguments" => Jason.encode!(%{"path" => "forbidden.txt", "content" => "oops"})
              }
            }
          ]
        }
      end
    end)

    on_exit(fn ->
      Application.put_env(:flux_claw, :llm, old_llm)
      Application.put_env(:flux_claw, :agents, old_agents)
      Application.put_env(:flux_claw, :cache_paths, old_paths)
      File.rm_rf!(memory_root)

      if old_reply,
        do: Application.put_env(:flux_claw, :llm_mock_reply, old_reply),
        else: Application.delete_env(:flux_claw, :llm_mock_reply)
    end)

    {:ok, session} = Agents.create_session(%{title: "plan", execution_mode: "plan"})
    root = FluxClaw.Artifacts.root(session.id)
    on_exit(fn -> File.rm_rf!(root) end)
    Phoenix.PubSub.subscribe(FluxClaw.PubSub, "agent:" <> session.id)
    worker = start_supervised!({AgentWorker, session_id: session.id})
    GenServer.cast(worker, {:user_message, "plan this"})
    assert_receive {:mode_prompt, prompt}, 2_000
    assert prompt =~ "当前为规划模式"
    assert_receive {:tool_done, "denied-write", "file_write", result}, 2_000
    assert result =~ "规划模式不允许"
    assert_receive {:assistant_done, "finished", _}, 2_000
    _ = :sys.get_state(worker)
    refute File.exists?(Path.join(root, "forbidden.txt"))
    refute File.exists?(memory_root)
    refute Repo.exists?(from s in FluxClaw.Memory.Skill, where: s.session_id == ^session.id)
    assert_receive {:mode_prompt, _}, 2_000
    {:ok, _} = Agents.update_session(session, %{execution_mode: "agent"})
    GenServer.cast(worker, {:user_message, "execute now"})
    assert_receive {:mode_prompt, prompt}, 2_000
    assert prompt =~ "当前为执行模式"
    assert_receive {:assistant_done, "finished", _}, 2_000
  end
end
