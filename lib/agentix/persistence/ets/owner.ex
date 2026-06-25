defmodule Agentix.Persistence.ETS.Owner do
  @moduledoc false
  # Owns the ETS adapter's named public tables and serializes the operations that

  use GenServer

  @tables [
    {:agentix_events, :ordered_set},
    {:agentix_conversations, :set},
    {:agentix_summaries, :ordered_set},
    {:agentix_tool_calls, :set},
    {:agentix_model_calls, :ordered_set}
  ]

  @expired_result %{ok: false, error: "tool call expired: no response"}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Atomically resolve a pending tool call; `{:error, :stale}` if not pending."
  @spec resolve(String.t(), atom(), map() | nil) :: :ok | {:error, :stale}
  def resolve(tool_call_id, status, result),
    do: GenServer.call(__MODULE__, {:resolve, tool_call_id, status, result})

  @spec schedule_expiry(String.t(), String.t(), pos_integer()) :: :ok
  def schedule_expiry(conversation_id, tool_call_id, timeout_ms),
    do: GenServer.call(__MODULE__, {:schedule_expiry, conversation_id, tool_call_id, timeout_ms})

  @spec cancel_expiry(String.t(), String.t()) :: :ok
  def cancel_expiry(conversation_id, tool_call_id),
    do: GenServer.call(__MODULE__, {:cancel_expiry, conversation_id, tool_call_id})

  @impl true
  def init(:ok) do
    Enum.each(@tables, fn {name, type} ->
      :ets.new(name, [type, :public, :named_table, read_concurrency: true])
    end)

    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_call({:resolve, tool_call_id, status, result}, _from, state) do
    {:reply, do_resolve(tool_call_id, status, result), state}
  end

  def handle_call({:schedule_expiry, conversation_id, tool_call_id, timeout_ms}, _from, state) do
    key = {conversation_id, tool_call_id}
    # Cancel any in-flight timer for this key so a reschedule can't leak a spurious
    # `{:expire, key}` message.
    case state.timers[key] do
      nil -> :ok
      existing -> Process.cancel_timer(existing)
    end

    ref = Process.send_after(self(), {:expire, key}, timeout_ms)
    {:reply, :ok, put_in(state.timers[key], ref)}
  end

  def handle_call({:cancel_expiry, conversation_id, tool_call_id}, _from, state) do
    {ref, timers} = Map.pop(state.timers, {conversation_id, tool_call_id})
    if ref, do: Process.cancel_timer(ref)
    {:reply, :ok, %{state | timers: timers}}
  end

  @impl true
  def handle_info({:expire, {_conv, tool_call_id} = key}, state) do
    do_resolve(tool_call_id, :expired, @expired_result)
    {:noreply, %{state | timers: Map.delete(state.timers, key)}}
  end

  defp do_resolve(tool_call_id, status, result) do
    case :ets.lookup(:agentix_tool_calls, tool_call_id) do
      [{^tool_call_id, %{status: :pending} = tool_call}] ->
        resolved = %{tool_call | status: status, result: result, resolved_at: DateTime.utc_now()}
        :ets.insert(:agentix_tool_calls, {tool_call_id, resolved})
        :ok

      _ ->
        {:error, :stale}
    end
  end
end
