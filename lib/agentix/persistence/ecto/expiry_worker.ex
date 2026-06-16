# Compiles only when Oban is available. `Agentix.Persistence.Ecto.schedule_expiry/3`
# guards on the same condition and raises a clear error if a host enables Ecto-backed
# expiry without adding `:oban`.
if Code.ensure_loaded?(Oban) do
  defmodule Agentix.Persistence.Ecto.ExpiryWorker do
    @moduledoc """
    Oban worker that expires a still-pending tool call after its suspension timeout.

    Durable by construction: the job lives in the database, so it fires even if the
    agent process that scheduled it was killed. Rescheduling the same call replaces the
    job's `scheduled_at` (the unique key is `conversation_id` + `tool_call_id`), so an
    earlier timer never leaks.
    """
    use Oban.Worker,
      queue: :agentix_expiry,
      unique: [
        keys: [:conversation_id, :tool_call_id],
        states: [:scheduled, :available, :executing, :retryable, :suspended],
        period: :infinity
      ]

    alias Agentix.Persistence

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"tool_call_id" => tool_call_id}}) do
      # Stale-safe: resolves to an error only if the call is still `:pending`; a call
      # already answered (or expired) is a no-op.
      Persistence.resolve_tool_call(tool_call_id, :expired, %{
        ok: false,
        error: "tool call expired: no response"
      })

      :ok
    end
  end
end
