defmodule FluxClaw.Agents.Orchestrator do
  @moduledoc "Spawns and addresses per-session AgentWorker processes under DynamicSupervisor."

  def ensure_worker(session_id) do
    case Registry.lookup(FluxClaw.Agents.Registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {FluxClaw.Agents.AgentWorker, session_id: session_id}

        case DynamicSupervisor.start_child(FluxClaw.Agents.AgentSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def send_message(session_id, text) when is_binary(text) do
    with {:ok, pid} <- ensure_worker(session_id) do
      GenServer.cast(pid, {:user_message, text})
      :ok
    end
  end

  def reply_ask_user(session_id, ref, answer) when is_integer(ref) and is_binary(answer) do
    case Registry.lookup(FluxClaw.Agents.Registry, session_id) do
      [{pid, _}] ->
        send(pid, {:ask_user_reply, ref, answer})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Forwards the user's keep/reject decision for a proposed diff to the session worker."
  def reply_diff_review(session_id, ref, decision) when is_integer(ref) do
    case Registry.lookup(FluxClaw.Agents.Registry, session_id) do
      [{pid, _}] ->
        send(pid, {:diff_review_reply, ref, decision})
        :ok

      [] ->
        :ok
    end
  end
end
