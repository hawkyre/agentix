defmodule Agentix.Conversation.Config do
  @moduledoc """
  Per-conversation configuration: which model, the system prompt, the (v0 fixed)
  tool list, and runtime knobs.

  The runtime knobs mirror the install/config contract:

    * `working_budget` — token budget for the assembled context.
    * `default_timeout` — suspension expiry default, in milliseconds.
    * `audit?` — record `model_calls` for replay/evals (off by default).
    * `persistence` / `notifier` / `pubsub` — wiring resolved at runtime; `nil`
      falls back to the application-level configuration.
  """

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t() | nil,
          tools: list(),
          working_budget: pos_integer(),
          default_timeout: pos_integer(),
          audit?: boolean(),
          persistence: module() | {module(), keyword()} | nil,
          notifier: module() | nil,
          pubsub: atom() | nil
        }

  # Default working-set token budget (~100–150 chat messages).
  @default_working_budget 30_000
  # Default suspension expiry, in milliseconds (5 minutes).
  @default_timeout_ms 300_000

  @enforce_keys [:model]
  defstruct [
    :model,
    system_prompt: nil,
    tools: [],
    working_budget: @default_working_budget,
    default_timeout: @default_timeout_ms,
    audit?: false,
    persistence: nil,
    notifier: nil,
    pubsub: nil
  ]

  @doc """
  Builds a config from `attrs`. Requires a non-empty `:model` string. Raises
  `ArgumentError` if `:model` is missing/blank, if `working_budget` or
  `default_timeout` is not a positive integer, or on unknown keys.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    validate_model!(Map.get(attrs, :model))

    config = struct!(__MODULE__, attrs)
    validate_positive!(:working_budget, config.working_budget)
    validate_positive!(:default_timeout, config.default_timeout)
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
end
