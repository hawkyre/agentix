defmodule Agentix.Telemetry.StreamOpenError do
  @moduledoc """
  The exception a `[:agentix, :model_call, :exception]` event carries as its
  `reason` when the provider stream failed to open (a pre-stream `{:error, reason}`
  from the provider). The original provider error is in the `:reason` field. A
  mid-stream crash carries the raised exception itself instead.
  """

  defexception [:reason]

  @impl true
  def message(%{reason: reason}), do: "provider stream open failed: #{inspect(reason)}"
end

defmodule Agentix.Telemetry do
  @moduledoc false
  # Nil-safe helpers for the [:agentix, :model_call] and [:agentix, :tool] telemetry
  # events (documented in guides/telemetry.md), and owner of the payload shapes those
  # events expose. Nothing here may raise — a telemetry payload must never take down
  # a turn, so every mapper degrades to nil on an unexpected shape.

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
      value when is_integer(value) and value >= 0 -> value
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

  ## [:agentix, :tool] emitters — the event's measurement/metadata shapes live here;
  ## the agent supplies only the identity metadata and the span's elapsed time.

  @doc false
  @spec tool_start(map()) :: :ok
  def tool_start(meta) do
    :telemetry.execute(
      [:agentix, :tool, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      meta
    )
  end

  @doc false
  @spec tool_stop(map(), integer(), map()) :: :ok
  def tool_stop(meta, duration, result) do
    :telemetry.execute(
      [:agentix, :tool, :stop],
      %{duration: duration, latency_ms: to_ms(duration), monotonic_time: System.monotonic_time()},
      Map.merge(meta, %{result: result, status: result_status(result)})
    )
  end

  @doc false
  @spec tool_exception(map(), integer(), term()) :: :ok
  def tool_exception(meta, duration, reason) do
    {cause, stacktrace} = crash_details(reason)

    :telemetry.execute(
      [:agentix, :tool, :exception],
      %{duration: duration, monotonic_time: System.monotonic_time()},
      Map.merge(meta, %{kind: :exit, reason: cause, stacktrace: stacktrace})
    )
  end

  @doc false
  @spec to_ms(integer()) :: integer()
  def to_ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  # An abnormal task exit is either `{exception_or_reason, stacktrace}` or a bare term.
  defp crash_details({reason, stacktrace}) when is_list(stacktrace), do: {reason, stacktrace}
  defp crash_details(reason), do: {reason, []}

  defp result_status(%{ok: true}), do: :ok
  defp result_status(%{"ok" => true}), do: :ok
  defp result_status(_result), do: :error
end
