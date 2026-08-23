defmodule Agentix.Telemetry do
  @moduledoc false
  # Nil-safe helpers for the [:agentix, :model_call] and [:agentix, :tool] telemetry
  # events (documented in guides/telemetry.md). Nothing here may raise — a telemetry
  # payload must never take down a turn, so every mapper degrades to nil on an
  # unexpected shape.

  alias ReqLLM.Message

  @usage_keys [:input_tokens, :output_tokens, :total_tokens, :cached_tokens]

  @doc """
  Maps a provider usage map onto the `:model_call` `:stop` token measurements.
  Accepts atom or string keys; a missing/non-integer field, or a non-map usage,
  yields nil for that measurement.
  """
  @spec usage_measurements(term()) :: %{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cached_tokens: non_neg_integer() | nil
        }
  def usage_measurements(usage) when is_map(usage) do
    Map.new(@usage_keys, fn key -> {key, usage_field(usage, key)} end)
  end

  def usage_measurements(_usage), do: Map.new(@usage_keys, &{&1, nil})

  defp usage_field(usage, key) do
    case Map.get(usage, key, Map.get(usage, Atom.to_string(key))) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  @doc """
  The finish reason for an assembled assistant message. The provider seam does not
  surface the native value (`Provider.Stream.finalize` returns only message + usage),
  so it is derived: `:tool_calls` when the message carries tool calls, else `:stop`.
  """
  @spec finish_reason(term()) :: :tool_calls | :stop
  def finish_reason(%Message{tool_calls: [_ | _]}), do: :tool_calls
  def finish_reason(_message), do: :stop
end
