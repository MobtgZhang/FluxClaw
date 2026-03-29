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

  @impl true
  def init(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    Logger.metadata(agent_id: sid)

    root = Application.fetch_env!(:flux_claw, :agents)[:sandbox_root]
    File.mkdir_p!(root)
    session_sandbox = Path.join(root, sid)
    File.mkdir_p!(session_sandbox)

    conversation = load_conversation_from_db(sid)

    {:ok,
     %{
       session_id: sid,
       conversation: conversation,
       memory: %Layered{},
       sandbox_root: session_sandbox,
       step: 0,
       pending: nil,
       last_user_text: nil,
       trace: []
     }}
  end

  defp load_conversation_from_db(sid) do
    sid
    |> Agents.list_messages()
    |> Enum.flat_map(&db_row_to_llm/1)
  end

  defp db_row_to_llm(%{role: "user", content: c}) when is_binary(c),
    do: [%{"role" => "user", "content" => c}]

  defp db_row_to_llm(%{role: "assistant", content: c}) when is_binary(c),
    do: [%{"role" => "assistant", "content" => c}]

  defp db_row_to_llm(_), do: []

  defp tool_name(call), do: get_in(call, ["function", "name"]) || "tool"

  @impl true
  def handle_cast({:user_message, text}, state) do
    :telemetry.execute([:flux_claw, :agent, :message], %{count: 1}, %{
      session_id: state.session_id
    })

    case Agents.append_message(state.session_id, %{role: "user", content: text}) do
      {:ok, _} ->
        conv = state.conversation ++ [%{"role" => "user", "content" => text}]
        broadcast(state.session_id, {:user, text})

        {:noreply, %{state | conversation: conv, step: 0, last_user_text: text, trace: []},
         {:continue, :run}}

      {:error, e} ->
        broadcast(state.session_id, {:error, inspect(e)})
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:run, state) do
    :telemetry.execute([:flux_claw, :agent, :step], %{count: 1}, %{session_id: state.session_id})

    max_steps = Application.get_env(:flux_claw, :agents, [])[:max_steps] || 32

    if state.step >= max_steps do
      broadcast(state.session_id, {:error, :max_steps})
      {:noreply, state}
    else
      run_llm_cycle(%{state | step: state.step + 1})
    end
  end

  defp run_llm_cycle(state) do
    Logger.metadata(agent_id: state.session_id)
    llm = FluxClaw.LLM.impl()
    tools = FluxClaw.Tool.openai_tools()
    messages = [system_message(state) | state.conversation]

    case llm.complete(messages, tools, []) do
      {:error, :missing_api_key} ->
        broadcast(state.session_id, {:error, :missing_api_key})
        {:noreply, state}

      {:error, reason} ->
        broadcast(state.session_id, {:error, reason})
        {:noreply, state}

      {:ok, %{tool_calls: calls} = resp} when is_list(calls) and calls != [] ->
        if resp.content && resp.content != "" do
          broadcast(state.session_id, {:assistant_delta, resp.content})
        end

        assistant_msg = assistant_api_message(resp)
        prefix = state.conversation ++ [assistant_msg]
        run_tool_calls(calls, state, prefix, [])

      {:ok, resp} ->
        text = resp.content || ""
        broadcast(state.session_id, {:assistant_delta, text})
        broadcast(state.session_id, {:assistant_done, text})

        case Agents.append_message(state.session_id, %{role: "assistant", content: text}) do
          {:ok, _} ->
            :ok

          {:error, e} ->
            Logger.warning("assistant persist failed: #{inspect(e)}")
        end

        conv = state.conversation ++ [%{"role" => "assistant", "content" => text}]
        state = %{state | conversation: conv, trace: [{:assistant, text} | state.trace]}
        maybe_crystallize(state)
        {:noreply, %{state | step: 0}}
    end
  end

  defp assistant_api_message(resp) do
    calls =
      resp.tool_calls
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
      "content" => resp.content,
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
    tool_msg = %{"role" => "tool", "tool_call_id" => id, "content" => text}
    broadcast(state.session_id, {:tool_done, id, text})

    tn = tool_name(call)

    trace =
      case Keyword.get(opts, :checkpoint) do
        nil -> [{:tool, tn, text} | state.trace]
        cp -> [{:checkpoint, cp} | [{:tool, tn, text} | state.trace]]
      end

    state = %{state | trace: trace}
    run_tool_calls(rest, state, prefix, tool_acc ++ [tool_msg])
  end

  defp apply_tool_opts(state, opts) do
    case Keyword.get(opts, :l2) do
      nil -> state
      map -> %{state | memory: %{state.memory | l2: Map.merge(state.memory.l2, map)}}
    end
  end

  @impl true
  def handle_info({:ask_user_reply, ref, answer}, state) do
    case state.pending do
      %{ref: ^ref, call: call, rest: rest, prefix: prefix, tool_acc: acc} ->
        append_tool_result(call, rest, state, prefix, acc, answer, [])

      _ ->
        {:noreply, state}
    end
  end

  defp system_message(state) do
    rules = Application.get_env(:flux_claw, :memory_l0, [])[:rules] || []
    l0 = Enum.join(rules, "\n")

    l3 =
      Memory.list_skills_for_prompt(state.last_user_text || "") |> Memory.skills_to_prompt_block()

    l2 =
      if map_size(state.memory.l2) > 0 do
        "Session facts (L2):\n" <> Jason.encode!(state.memory.l2)
      else
        ""
      end

    parts = [l0, l2, if(l3 != "", do: "Relevant skills (L3):\n" <> l3, else: "")]
    %{"role" => "system", "content" => parts |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")}
  end

  defp maybe_crystallize(state) do
    enabled = Application.get_env(:flux_claw, :agents, [])[:crystallize_skills]
    tool_trace? = Enum.any?(state.trace, &match?({:tool, _, _}, &1))

    if enabled && tool_trace? && state.last_user_text && state.last_user_text != "" do
      title = state.last_user_text |> String.slice(0, 120)
      body = skill_body_from_trace(state.trace)
      keywords = state.last_user_text

      case Memory.create_skill(%{
             title: title,
             body: body,
             keywords: keywords,
             session_id: state.session_id
           }) do
        {:ok, _} ->
          broadcast(state.session_id, {:skill_saved, title})

        {:error, e} ->
          Logger.warning("skill crystallize failed: #{inspect(e)}")
      end
    end

    :ok
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
