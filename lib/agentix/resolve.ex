defmodule Agentix.Resolve do
  @moduledoc false
  # Resolution path for a suspended tool call, backing the public `Agentix.resolve/4`.

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
