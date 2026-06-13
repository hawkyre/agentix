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
end
