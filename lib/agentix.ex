defmodule Agentix do
  @moduledoc """
  Agentix — a LiveView-native library for building agentic systems in Elixir.

  Agentix provides an agent runtime (one `:gen_statem` process per
  conversation), an explicit tool/HITL model, a per-turn hook pipeline,
  reducer-based compaction, and a headless LiveView rendering layer. It builds
  on [ReqLLM](https://hexdocs.pm/req_llm) for provider abstraction and the
  canonical typed model (`Context`, `Message`, `ContentPart`, `Tool`,
  `StreamChunk`, `Response`, `Usage`).
  """

  alias Agentix.Resolve
  alias Agentix.Scope

  @doc """
  Resolves a suspended tool call. Public and not socket-bound — a LiveView,
  webhook, job, or timeout all call it the same way. `scope` defaults to the system
  scope (the documented scope for timeout-driven resolutions).

  Returns `:ok` if the id was pending, or `{:error, :stale}` if it is unknown or
  already resolved.
  """
  @spec resolve(String.t(), String.t(), term(), Scope.t()) :: :ok | {:error, term()}
  def resolve(conversation_id, tool_call_id, result, scope \\ Scope.system()) do
    Resolve.resolve(conversation_id, tool_call_id, result, scope)
  end

  @doc """
  The structured-output object an assistant message carries, or `nil`.

  When a turn runs with a `:schema` (per-turn) or the conversation's `response_format`
  default, the model's typed result is stored in the assistant message's
  `metadata["object"]`. This reads it back from a `ReqLLM.Message` (e.g. the one in a
  `{:message_completed, ref, message}` live event, or from `Agentix.Chat`). Returns
  `nil` for an ordinary (plain-text) message.
  """
  @spec object(ReqLLM.Message.t()) :: term() | nil
  def object(%ReqLLM.Message{metadata: metadata}) when is_map(metadata), do: metadata["object"]
  def object(_message), do: nil
end
