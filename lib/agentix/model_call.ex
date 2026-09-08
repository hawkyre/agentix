defmodule Agentix.ModelCall do
  @moduledoc false

  alias Agentix.Codec
  alias Agentix.Conversation.Config
  alias Agentix.Persistence

  @spec record(String.t(), Config.t(), ReqLLM.Context.t(), map()) :: :ok
  def record(conversation_id, config, context, outcome) do
    level = log_level(config)

    if level == :off do
      :ok
    else
      record =
        outcome
        |> Map.delete(:started_at)
        |> Map.merge(%{
          model: config.model,
          usage: outcome[:usage] || %{},
          error: describe_error(outcome[:error]),
          latency_ms:
            System.convert_time_unit(
              System.monotonic_time() - outcome.started_at,
              :native,
              :millisecond
            ),
          rendered_context: rendered_context(level, context),
          tenant_key: config.tenant_key,
          feature: config.feature,
          pricing_version: pricing_version()
        })

      Persistence.append_model_call(conversation_id, record)
    end
  end

  defp log_level(%Config{model_call_log: level}) when level in [:records, :full], do: level

  defp log_level(_config) do
    case Application.get_env(:agentix, :model_call_log) do
      level when level in [:off, :records, :full] -> level
      _unset -> if Application.get_env(:agentix, :audit, false), do: :full, else: :off
    end
  end

  # Unvalidated limit for stored error descriptions.
  @max_error_bytes 500

  defp describe_error(nil), do: nil

  defp describe_error(reason) do
    reason
    |> inspect(printable_limit: @max_error_bytes)
    |> String.slice(0, @max_error_bytes)
  end

  defp rendered_context(:full, context), do: Jason.decode!(Codec.encode!(context))
  defp rendered_context(_level, _context), do: nil

  defp pricing_version do
    case Application.spec(:llm_db, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end
end
