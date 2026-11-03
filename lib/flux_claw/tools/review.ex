defmodule FluxClaw.Tools.Review do
  @moduledoc """
  Code-edit / diff-review flow (Codex / Claude Code style).

  Instead of silently writing files, tools that modify sandbox files can
  propose the change as a unified diff and suspend the agent loop until the
  user keeps or rejects it in the UI. The proposal is broadcast to the
  LiveView as `{:diff_proposed, ref, payload}` and the loop resumes on
  `{:diff_review_reply, ref, decision}`.

  Enabled by default; configure via:

      config :flux_claw, :agents, review_edits: false
  """

  alias FluxClaw.Tools.Diff

  @type payload :: %{optional(String.t()) => term()}

  @doc "Whether edits must go through the keep/reject review flow."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:flux_claw, :agents, [])[:review_edits] != false
  end

  @doc """
  Propose writing `new_content` to `abs_path` (displayed as `rel_path`).

  Returns:

    * `{:ok, message}` when review is disabled and the write succeeded, or
      when the content is unchanged.
    * `{:error, reason}` on a failed write.
    * `{:suspend_review, ref, payload}` when review is enabled — the caller
      (AgentWorker) must suspend and wait for the user's decision; it owns
      the actual `File.write` on "keep".
  """
  @spec propose_write(map(), String.t(), String.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
          | {:suspend_review, pos_integer(), payload()}
  def propose_write(ctx, rel_path, abs_path, old_content, new_content, tool) do
    diff = Diff.unified_diff(old_content, new_content, rel_path)

    cond do
      diff == "" ->
        {:ok, "no changes (content identical)"}

      enabled?() ->
        ref = :erlang.unique_integer([:positive])

        payload = %{
          "tool" => tool,
          "path" => rel_path,
          "abs_path" => abs_path,
          "diff" => diff,
          "new_content" => new_content,
          "session_id" => Map.get(ctx, :session_id) && to_string(Map.get(ctx, :session_id))
        }

        {:suspend_review, ref, payload}

      true ->
        case File.write(abs_path, new_content) do
          :ok -> {:ok, "wrote #{byte_size(new_content)} bytes to #{rel_path}"}
          {:error, r} -> {:error, inspect(r)}
        end
    end
  end

  @doc "Apply the user's keep decision: write `payload[\"new_content\"]` to disk."
  @spec apply_kept(payload()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_kept(payload) when is_map(payload) do
    abs = Map.fetch!(payload, "abs_path")
    content = Map.fetch!(payload, "new_content")
    rel = Map.fetch!(payload, "path")

    abs |> Path.dirname() |> File.mkdir_p!()

    case File.write(abs, content) do
      :ok -> {:ok, "kept: wrote #{byte_size(content)} bytes to #{rel}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end
end
