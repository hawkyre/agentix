defmodule Agentix.Resolve do
  @moduledoc """
  The public resolution path for a suspended tool call.

  `resolve/4` is not socket-bound — a LiveView, a webhook, a job, or a timeout all
  call the same function. It enters through `Agentix.Conversation.ensure_started/2`,
  so a conversation suspended on a `:human`/`:client` call is revived by the answer
  if its agent was evicted. The call replies immediately:

    * `:ok` — the id was pending and the result was recorded (the turn then resumes
      asynchronously);
    * `{:error, :stale}` — the id is unknown or already resolved/expired (covers
      double-clicks, resubmits, and the kill→revive→late-answer race).
  """

  alias Agentix.Agent
  alias Agentix.Conversation
  alias Agentix.Scope

  @doc "Resolves `tool_call_id` in `conversation_id` with `result` under `scope`."
  @spec resolve(String.t(), String.t(), term(), Scope.t()) :: :ok | {:error, term()}
  def resolve(conversation_id, tool_call_id, result, %Scope{} = scope) do
    with {:ok, _pid} <- Conversation.ensure_started(conversation_id) do
      :gen_statem.call(Agent.via(conversation_id), {:resolve, tool_call_id, result, scope})
    end
  end
end
