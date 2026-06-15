defmodule Agentix.Conversation.Config do
  @moduledoc """
  Per-conversation configuration: which model, the system prompt, the (v0 fixed)
  tool list, and runtime knobs.

  The runtime knobs mirror the install/config contract:

    * `working_budget` — token budget for the assembled context.
    * `injection_reserve` — token budget reserved for pre-hook injections (D7);
      over-reserve injection is a loud `Agentix.Hook.OverflowError`.
    * `default_timeout` — suspension expiry default, in milliseconds.
    * `hook_timeout` — per parallel pre-hook deadline, in milliseconds; a hook that
      exceeds it is shut down and recorded as a crashed (skipped) injector. Sequential
      hooks run inline and are the author's responsibility to keep bounded.
    * `audit?` — record `model_calls` for replay/evals (off by default).
    * `hooks` — `Agentix.Hook` structs run around each model call (Inc 7).
    * `stream_transformer` — a `(chunk -> chunk)` seam applied to each stream chunk
      (`nil` is the identity default).
    * `persistence` / `notifier` / `pubsub` — wiring resolved at runtime; `nil`
      falls back to the application-level configuration.

  Like `tools`, `hooks`/`stream_transformer` are functions, not JSON-serializable;
  they live here and are rebuilt from config on revival (verbatim for the ETS adapter).
  """

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t() | nil,
          tools: list(),
          hooks: [Agentix.Hook.t()],
          stream_transformer: (term() -> term()) | nil,
          working_budget: pos_integer(),
          injection_reserve: pos_integer(),
          default_timeout: pos_integer(),
          hook_timeout: pos_integer(),
          audit?: boolean(),
          persistence: module() | {module(), keyword()} | nil,
          notifier: module() | nil,
          pubsub: atom() | nil
        }

  # Default working-set token budget (~100–150 chat messages).
  @default_working_budget 30_000
  # Default reserve for pre-hook injections (~tokens), carved out of the budget.
  @default_injection_reserve 4_000
  # Default suspension expiry, in milliseconds (5 minutes).
  @default_timeout_ms 300_000
  # Default per parallel pre-hook deadline, in milliseconds.
  @default_hook_timeout_ms 5_000

  @enforce_keys [:model]
  defstruct [
    :model,
    system_prompt: nil,
    tools: [],
    hooks: [],
    stream_transformer: nil,
    working_budget: @default_working_budget,
    injection_reserve: @default_injection_reserve,
    default_timeout: @default_timeout_ms,
    hook_timeout: @default_hook_timeout_ms,
    audit?: false,
    persistence: nil,
    notifier: nil,
    pubsub: nil
  ]

  @doc """
  Builds a config from `attrs`. Requires a non-empty `:model` string. Raises
  `ArgumentError` if `:model` is missing/blank, if `working_budget`,
  `injection_reserve`, `default_timeout`, or `hook_timeout` is not a positive
  integer, if `stream_transformer` is neither `nil` nor a 1-arity function, or on
  unknown keys.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    validate_model!(Map.get(attrs, :model))

    config = struct!(__MODULE__, attrs)
    validate_positive!(:working_budget, config.working_budget)
    validate_positive!(:injection_reserve, config.injection_reserve)
    validate_positive!(:default_timeout, config.default_timeout)
    validate_positive!(:hook_timeout, config.hook_timeout)
    validate_transformer!(config.stream_transformer)
    config
  end

  defp validate_model!(model) when is_binary(model) and model != "", do: :ok

  defp validate_model!(other) do
    raise ArgumentError,
          "Agentix.Conversation.Config requires a non-empty :model string, got: #{inspect(other)}"
  end

  defp validate_positive!(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(field, value) do
    raise ArgumentError, "#{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_transformer!(nil), do: :ok
  defp validate_transformer!(fun) when is_function(fun, 1), do: :ok

  defp validate_transformer!(other) do
    raise ArgumentError,
          "stream_transformer must be nil or a 1-arity (chunk -> chunk) function, " <>
            "got: #{inspect(other)}"
  end
end
