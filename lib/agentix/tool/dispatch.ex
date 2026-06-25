defmodule Agentix.Tool.Dispatch do
  @moduledoc false
  # Runs a `:server` tool callback off the agent process.

  alias Agentix.Tool
  alias Agentix.Turn

  @doc """
  Spawns the monitored task that runs `tool`'s callback and reports back to `agent`.
  Returns the `%Task{}` so the caller can track / shut it down.
  """
  @spec run_server(pid(), term(), String.t(), Tool.t(), map(), Turn.t()) :: Task.t()
  def run_server(agent, turn_ref, tool_call_id, %Tool{callback: callback}, args, %Turn{} = turn) do
    # Stamp the call's coordinates so the callback can stream progress back via
    # `Agentix.Turn.report_progress/2`.
    turn = %{turn | agent: agent, tool_call_id: tool_call_id}

    Task.Supervisor.async_nolink(Agentix.TaskSupervisor, fn ->
      result =
        try do
          args |> callback.(turn) |> normalize_result()
        rescue
          error -> %{ok: false, error: Exception.message(error)}
        end

      send(agent, {:tool_done, turn_ref, tool_call_id, result})
    end)
  end

  @doc """
  Coerces a callback return (or any resolution value) into the model-visible result
  convention: `%{ok: true, result: ...}` / `%{ok: false, error: ...}`.
  """
  @spec normalize_result(term()) :: %{required(:ok) => boolean(), optional(atom()) => term()}
  def normalize_result(%{ok: ok} = result) when is_boolean(ok), do: result
  def normalize_result({:ok, value}), do: %{ok: true, result: value}
  def normalize_result({:error, reason}), do: %{ok: false, error: reason}
  def normalize_result(value), do: %{ok: true, result: value}
end
