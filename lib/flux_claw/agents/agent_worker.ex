defmodule FluxClaw.Agents.AgentWorker do
  @moduledoc "GenericAgent-style loop: LLM -> tools -> memory, per session OTP process."
  use GenServer

  require Logger

  alias FluxClaw.Agents
  alias FluxClaw.Memory
  alias FluxClaw.Memory.Layered

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def child_spec(opts) do
    sid = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, sid},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  defp via(id), do: {:via, Registry, {FluxClaw.Agents.Registry, id}}

  @doc """
  True when the persisted conversation ends with a user message or tool result,
  so a worker should run to continue the agent loop. Empty or assistant-final sessions
  do not need a process until the user sends again.
  """
  def needs_resume?(session_id) when is_binary(session_id) do
    conversation = load_conversation_from_db(session_id)
    should_auto_resume?(conversation)
  end

  @impl true
  def init(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    Logger.metadata(agent_id: sid)

    project_id =
      case Agents.get_session(sid) do
        %{project_id: pid} when is_binary(pid) -> pid
        _ -> FluxClaw.Projects.ensure_default_project().id
      end

    root = Application.fetch_env!(:flux_claw, :agents)[:sandbox_root]
    File.mkdir_p!(root)
    session_sandbox = Path.join(root, sid)
    File.mkdir_p!(session_sandbox)

    conversation = load_conversation_from_db(sid)

    state = %{
      session_id: sid,
      project_id: project_id,
      conversation: conversation,
      memory: %Layered{},
      l1: %{},
      sandbox_root: session_sandbox,
      step: 0,
      pending: nil,
      last_user_text: nil,
      trace: []
    }

    if should_auto_resume?(conversation) do
      {:ok, state, {:continue, :run}}
    else
      {:ok, state}
    end
  end

  defp should_auto_resume?(msgs) do
    case List.last(msgs) do
      %{"role" => "user"} -> true
      %{"role" => "tool"} -> true
      _ -> false
    end
  end

  defp load_conversation_from_db(sid) do
    sid
    |> Agents.list_messages()
    |> Enum.flat_map(&db_row_to_llm/1)
  end

  defp db_row_to_llm(%{role: "reasoning"}), do: []

  defp db_row_to_llm(%{role: "user", content: c}) when is_binary(c),
    do: [%{"role" => "user", "content" => c}]

  defp db_row_to_llm(%{role: "assistant", content: c, metadata: meta})
       when is_map(meta) do
    tc = tool_calls_from_meta(meta)

    if tc != [] do
      [%{"role" => "assistant", "content" => c || "", "tool_calls" => tc}]
    else
      db_row_to_llm(%{role: "assistant", content: c, metadata: %{}})
    end
  end

  defp db_row_to_llm(%{role: "assistant", content: c}) when is_binary(c) and c != "",
    do: [%{"role" => "assistant", "content" => c}]

  defp db_row_to_llm(%{role: "assistant"}), do: []

  defp db_row_to_llm(%{role: "tool", metadata: meta} = row) when is_map(meta) do
    case tool_phase(meta) do
      "start" ->
        []

      "done" ->
        id = call_id_from_meta(meta)
        c = Map.get(row, :content) || ""
        [%{"role" => "tool", "tool_call_id" => id, "content" => c}]

      _ ->
        []
    end
  end

  defp db_row_to_llm(_), do: []

  defp tool_phase(nil), do: nil

  defp tool_phase(meta) when is_map(meta) do
    Map.get(meta, "phase") || Map.get(meta, :phase)
  end

  defp tool_phase(_), do: nil

  defp call_id_from_meta(nil), do: "call"

  defp call_id_from_meta(meta) when is_map(meta) do
    Map.get(meta, "call_id") || Map.get(meta, :call_id) || "call"
  end

  defp call_id_from_meta(_), do: "call"

  defp tool_calls_from_meta(nil), do: []

  defp tool_calls_from_meta(meta) when is_map(meta) do
    raw = Map.get(meta, "tool_calls") || Map.get(meta, :tool_calls)

    cond do
      is_list(raw) -> raw
      is_map(raw) and map_size(raw) > 0 -> [raw]
      true -> []
    end
  end

  defp tool_calls_from_meta(_), do: []

  defp tool_name(call), do: get_in(call, ["function", "name"]) || "tool"

  defp effective_max_steps do
    case Application.get_env(:flux_claw, :agents, [])[:max_steps] do
      n when n == -1 -> 999_999
      # 0：仅对话模式，单次补全、不注册工具
      n when n == 0 -> 1
      n when is_integer(n) and n > 0 -> n
      _ -> 32
    end
  end

  defp chat_only_mode? do
    Application.get_env(:flux_claw, :agents, [])[:max_steps] == 0
  end

  @impl true
  def handle_cast({:user_message, text}, state) do
    :telemetry.execute([:flux_claw, :agent, :message], %{count: 1}, %{
      session_id: state.session_id
    })

    case Agents.append_message(state.session_id, %{role: "user", content: text}) do
      {:ok, _} ->
        _ = maybe_autotitle_session(state.session_id, text)
        conv = state.conversation ++ [%{"role" => "user", "content" => text}]
        broadcast(state.session_id, {:user, text})

        {:noreply,
         %{state | conversation: conv, step: 0, last_user_text: text, trace: [], l1: %{}},
         {:continue, :run}}

      {:error, e} ->
        broadcast(state.session_id, {:error, inspect(e)})
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:run, state) do
    :telemetry.execute([:flux_claw, :agent, :step], %{count: 1}, %{session_id: state.session_id})

    max_steps = effective_max_steps()

    if state.step >= max_steps do
      broadcast(state.session_id, {:error, :max_steps})
      {:noreply, state}
    else
      state = %{state | step: state.step + 1}
      sid = state.session_id
      parent = self()

      _ =
        Task.start(fn ->
          try do
            stream_llm(parent, sid, state)
          rescue
            e ->
              send(parent, {:agent_llm_done, sid, state, {:error, e}})
          end
        end)

      {:noreply, state}
    end
  end

  defp stream_llm(parent, sid, state) do
    llm = FluxClaw.LLM.impl()
    tools = if(chat_only_mode?(), do: [], else: FluxClaw.Tool.openai_tools())
    messages = [system_message(state) | state.conversation]

    cb = fn
      {:reasoning_delta, d} ->
        send(parent, {:agent_pub, sid, {:reasoning_delta, d}})

      {:content_delta, d} ->
        send(parent, {:agent_pub, sid, {:assistant_delta, d}})

      {:error, e} ->
        send(parent, {:agent_pub, sid, {:llm_error, e}})

      :done ->
        :ok
    end

    result = llm.stream(messages, tools, [], cb)
    send(parent, {:agent_llm_done, sid, state, result})
  end

  @impl true
  def handle_info({:agent_pub, sid, {:llm_error, e}}, %{session_id: sid} = state) do
    broadcast(sid, {:error, e})
    {:noreply, %{state | step: 0}}
  end

  def handle_info({:agent_pub, sid, evt}, %{session_id: sid} = state) do
    broadcast(sid, evt)
    {:noreply, state}
  end

  def handle_info({:agent_llm_done, sid, _snap, {:error, e}}, %{session_id: sid} = state) do
    broadcast(sid, {:error, e})
    {:noreply, %{state | step: 0}}
  end

  def handle_info({:agent_llm_done, sid, _snap, {:ok, resp}}, %{session_id: sid} = state) do
    apply_llm_response(state, resp)
  end

  def handle_info({:ask_user_reply, ref, answer}, state) do
    case state.pending do
      %{ref: ^ref, call: call, rest: rest, prefix: prefix, tool_acc: acc} ->
        append_tool_result(call, rest, state, prefix, acc, answer, [])

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp apply_llm_response(state, resp) do
    reasoning = Map.get(resp, :reasoning) || Map.get(resp, "reasoning")

    if is_binary(reasoning) and reasoning != "" do
      _ = persist_reasoning(state.session_id, reasoning)
      broadcast(state.session_id, {:reasoning_done, reasoning})
    end

    calls = List.wrap(Map.get(resp, :tool_calls) || Map.get(resp, "tool_calls"))

    cond do
      chat_only_mode?() and calls != [] ->
        resp = Map.put(resp, :tool_calls, [])
        finalize_text_response(state, resp)

      calls != [] ->
        apply_tool_calls_response(state, resp, calls)

      true ->
        finalize_text_response(state, resp)
    end
  end

  defp apply_tool_calls_response(state, resp, calls) do
    text = Map.get(resp, :content) || Map.get(resp, "content") || ""

    # Persist before broadcasting assistant_done so LiveView's needs_resume?/DB sees the new tail.
    _ = persist_assistant_tool_calls(state.session_id, text, calls)

    if text != "" do
      broadcast(state.session_id, {:assistant_done, text})
    end

    assistant_msg = assistant_api_message(resp)
    prefix = state.conversation ++ [assistant_msg]
    run_tool_calls(calls, state, prefix, [])
  end

  defp finalize_text_response(state, resp) do
    text = Map.get(resp, :content) || Map.get(resp, "content") || ""

    case Agents.append_message(state.session_id, %{
           role: "assistant",
           content: text,
           metadata: %{}
         }) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        Logger.warning("assistant persist failed: #{inspect(e)}")
    end

    broadcast(state.session_id, {:assistant_done, text})

    tools_used = trace_tool_names(state.trace)

    if tools_used != "" do
      _ =
        Memory.append_evolution_episode(
          state.session_id,
          state.last_user_text,
          tools_used,
          text
        )
    end

    conv = state.conversation ++ [%{"role" => "assistant", "content" => text}]
    state = %{state | conversation: conv, trace: [{:assistant, text} | state.trace]}
    maybe_crystallize(state)
    {:noreply, %{state | step: 0}}
  end

  defp trace_tool_names(trace) do
    trace
    |> Enum.filter(&match?({:tool, _, _}, &1))
    |> Enum.map(fn {_, n, _} -> n end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp assistant_api_message(resp) do
    calls =
      (Map.get(resp, :tool_calls) || Map.get(resp, "tool_calls"))
      |> List.wrap()
      |> Enum.map(fn c ->
        f = c["function"] || %{}
        id = c["id"] || "call"

        %{
          "id" => id,
          "type" => "function",
          "function" => %{
            "name" => f["name"],
            "arguments" => f["arguments"] || "{}"
          }
        }
      end)

    %{
      "role" => "assistant",
      "content" => Map.get(resp, :content) || Map.get(resp, "content"),
      "tool_calls" => calls
    }
  end

  defp run_tool_calls([], state, prefix, tool_acc) do
    conv = prefix ++ tool_acc
    {:noreply, %{state | conversation: conv, pending: nil}, {:continue, :run}}
  end

  defp run_tool_calls([call | rest], state, prefix, tool_acc) do
    f = call["function"] || %{}
    name = f["name"]
    args_json = f["arguments"] || "{}"

    with {:ok, args} <- Jason.decode(args_json) do
      ctx = %{session_id: state.session_id, sandbox_root: state.sandbox_root}
      _ = persist_tool_start(state.session_id, name, args)
      broadcast(state.session_id, {:tool_start, name, args})

      case FluxClaw.Tool.run(name, args, ctx) do
        {:suspend_ask, ref, question} ->
          broadcast(state.session_id, {:ask_user, ref, question})

          pending = %{
            ref: ref,
            call: call,
            rest: rest,
            prefix: prefix,
            tool_acc: tool_acc
          }

          {:noreply, %{state | pending: pending}}

        {:ok, text} ->
          append_tool_result(call, rest, state, prefix, tool_acc, text, [])

        {:ok, text, opts} when is_list(opts) ->
          state = apply_tool_opts(state, opts)
          append_tool_result(call, rest, state, prefix, tool_acc, text, opts)

        {:error, e} ->
          append_tool_result(call, rest, state, prefix, tool_acc, "error: #{e}", [])
      end
    else
      _ ->
        append_tool_result(
          call,
          rest,
          state,
          prefix,
          tool_acc,
          "error: invalid tool arguments JSON",
          []
        )
    end
  end

  defp append_tool_result(call, rest, state, prefix, tool_acc, text, opts) do
    id = call["id"] || "call"
    tn = tool_name(call)
    tool_msg = %{"role" => "tool", "tool_call_id" => id, "content" => text}
    _ = persist_tool_done(state.session_id, id, tn, text)
    broadcast(state.session_id, {:tool_done, id, tn, text})

    trace =
      case Keyword.get(opts, :checkpoint) do
        nil -> [{:tool, tn, text} | state.trace]
        cp -> [{:checkpoint, cp} | [{:tool, tn, text} | state.trace]]
      end

    state = %{state | trace: trace}
    run_tool_calls(rest, state, prefix, tool_acc ++ [tool_msg])
  end

  defp apply_tool_opts(state, opts) do
    state
    |> then(fn s ->
      case Keyword.get(opts, :l2) do
        nil -> s
        map -> %{s | memory: %{s.memory | l2: Map.merge(s.memory.l2, map)}}
      end
    end)
    |> then(fn s ->
      case Keyword.get(opts, :l1) do
        nil -> s
        map -> %{s | l1: Map.merge(s.l1, map)}
      end
    end)
  end

  defp system_message(state) do
    rules = Application.get_env(:flux_claw, :memory_l0, [])[:rules] || []
    l0 = Enum.join(rules, "\n")

    l3 =
      Memory.list_skills_for_prompt(state.last_user_text || "", state.project_id)
      |> Memory.skills_to_prompt_block()

    l2 =
      if map_size(state.memory.l2) > 0 do
        "Session facts (L2):\n" <> Jason.encode!(state.memory.l2)
      else
        ""
      end

    l1 =
      if map_size(state.l1) > 0 do
        "Working scratch (L1):\n" <> Jason.encode!(state.l1)
      else
        ""
      end

    parts = [
      l0,
      l1,
      l2,
      if(l3 != "", do: "Relevant skills (L3):\n" <> l3, else: "")
    ]

    %{"role" => "system", "content" => parts |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")}
  end

  defp maybe_crystallize(state) do
    enabled = Application.get_env(:flux_claw, :agents, [])[:crystallize_skills]
    mode = Application.get_env(:flux_claw, :agents, [])[:crystallize_mode] || :auto
    tool_trace? = Enum.any?(state.trace, &match?({:tool, _, _}, &1))

    if enabled && tool_trace? && state.last_user_text && state.last_user_text != "" do
      title = state.last_user_text |> String.slice(0, 120)
      body = skill_body_from_trace(state.trace)
      keywords = state.last_user_text

      attrs = %{
        title: title,
        body: body,
        keywords: keywords,
        session_id: state.session_id,
        project_id: state.project_id,
        source: "crystallized"
      }

      case mode do
        :confirm ->
          broadcast(state.session_id, {:skill_proposal, attrs})

        _ ->
          case Memory.create_skill(attrs) do
            {:ok, _} ->
              broadcast(state.session_id, {:skill_saved, title})
              append_evolution_log(state)

            {:error, e} ->
              Logger.warning("skill crystallize failed: #{inspect(e)}")
          end
      end
    end

    :ok
  end

  defp append_evolution_log(state) do
    if Application.get_env(:flux_claw, :agents, [])[:self_evolve] do
      case Memory.cache_path(:memory_root) do
        root when is_binary(root) and root != "" ->
          File.mkdir_p!(root)
          path = Path.join(root, "evolution_log.md")

          stamp =
            DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

          summary = skill_body_from_trace(state.trace) |> String.slice(0, 1200)

          block = """
          \n## #{stamp} — #{String.slice(state.session_id, 0, 8)}
          #{summary}\n
          """

          _ = File.write(path, block, [:append])

        _ ->
          :ok
      end
    end

    :ok
  end

  defp maybe_autotitle_session(sid, user_text) do
    case Agents.get_session(sid) do
      nil ->
        :ok

      %{title: title} = session ->
        if title in ["新对话"] do
          new_title =
            user_text
            |> String.trim()
            |> String.replace(~r/\s+/, " ")
            |> String.slice(0, 56)

          new_title = if new_title == "", do: "对话", else: new_title

          case Agents.update_session(session, %{title: new_title}) do
            {:ok, _} -> broadcast(sid, {:session_title_updated, new_title})
            _ -> :ok
          end
        else
          :ok
        end
    end
  end

  defp persist_reasoning(sid, text) when is_binary(text) and text != "" do
    Agents.append_message(sid, %{role: "reasoning", content: text, metadata: %{}})
  end

  defp persist_reasoning(_, _), do: :ok

  defp persist_assistant_tool_calls(sid, text, calls) when is_list(calls) do
    stored =
      Enum.map(calls, fn c ->
        f = c["function"] || %{}
        id = c["id"] || "call"

        %{
          "id" => id,
          "type" => "function",
          "function" => %{
            "name" => f["name"],
            "arguments" => f["arguments"] || "{}"
          }
        }
      end)

    Agents.append_message(sid, %{
      role: "assistant",
      content: text || "",
      metadata: %{"tool_calls" => stored}
    })
  end

  defp persist_tool_start(sid, name, args) do
    Agents.append_message(sid, %{
      role: "tool",
      tool_name: name,
      content: Jason.encode!(args),
      metadata: %{"phase" => "start"}
    })
  end

  defp persist_tool_done(sid, id, tool_name, text) do
    Agents.append_message(sid, %{
      role: "tool",
      tool_name: tool_name,
      content: text,
      metadata: %{"phase" => "done", "call_id" => id}
    })
  end

  defp skill_body_from_trace(trace) do
    trace
    |> Enum.reverse()
    |> Enum.map_join("\n", fn
      {:assistant, t} -> "Assistant: #{t}"
      {:tool, n, t} -> "Tool #{n}: #{String.slice(t, 0, 500)}"
      {:checkpoint, %{label: l}} -> "Checkpoint: #{l}"
      _ -> ""
    end)
  end

  defp broadcast(session_id, msg) do
    Phoenix.PubSub.broadcast(FluxClaw.PubSub, topic(session_id), msg)
  end

  defp topic(sid), do: "agent:" <> sid
end
