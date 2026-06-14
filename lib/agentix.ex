defmodule Agentix do
  @moduledoc """
  Agentix — a LiveView-native library for building agentic systems in Elixir.

  Agentix provides an agent runtime (one `:gen_statem` process per
  conversation), an explicit tool/HITL model, a per-turn hook pipeline,
  reducer-based compaction, and a headless LiveView rendering layer. It builds
  on [ReqLLM](https://hexdocs.pm/req_llm) for provider abstraction and the
  canonical typed model (`Context`, `Message`, `ContentPart`, `Tool`,
  `StreamChunk`, `Response`, `Usage`).

  This is the pre-implementation scaffold; see the design docs for architecture
  and v0 scope.
  """

  alias Agentix.Resolve
  alias Agentix.Scope

  @doc """
  Resolves a suspended tool call. Public and not socket-bound — see
  `Agentix.Resolve`. `scope` defaults to the system scope (the documented scope for
  timeout-driven resolutions).

  Returns `:ok` if the id was pending, or `{:error, :stale}` if it is unknown or
  already resolved.
  """
  @spec resolve(String.t(), String.t(), term(), Scope.t()) :: :ok | {:error, term()}
  def resolve(conversation_id, tool_call_id, result, scope \\ Scope.system()) do
    Resolve.resolve(conversation_id, tool_call_id, result, scope)
  end
end
