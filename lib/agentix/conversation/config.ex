defmodule Agentix.Conversation.Config do
  @moduledoc """
  Per-conversation configuration: which model, the system prompt, the (fixed)
  tool list, and runtime knobs.

  The runtime knobs mirror the install/config contract:

    * `working_budget` — token budget for the assembled context.
    * `injection_reserve` — token budget reserved for pre-hook injections;
      over-reserve injection is a loud `Agentix.Hook.OverflowError`.
    * `tool_retention` — global default tool-result retention
      (`%{mode: :age | :count, value: pos_integer, never_evict: boolean}`; a tool's
      own `:retention` overrides it). **Reserved**: the tool-result reducer is not
      wired into the assembly path, so this is not currently applied.
    * `compaction_window` — how many recent turns the sliding-window reducer keeps
      verbatim. **Reserved**: the sliding-window reducer is not wired into the
      assembly path, so this is not currently applied.
    * `default_timeout` — suspension expiry default, in milliseconds.
    * `hook_timeout` — per parallel pre-hook deadline, in milliseconds; a hook that
      exceeds it is shut down and recorded as a crashed (skipped) injector. Sequential
      hooks run inline and are the author's responsibility to keep bounded.
    * `audit?` — record `model_calls` for replay/evals (off by default).
    * `hooks` — `Agentix.Hook` structs run around each model call.
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
          tool_retention: %{mode: :age | :count, value: pos_integer(), never_evict: boolean()},
          compaction_window: pos_integer(),
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
  # Default tool-result retention: keep full results for the last 6 turns.
  @default_tool_retention %{mode: :age, value: 6, never_evict: false}
  # Default recent-turn window the sliding-window reducer keeps verbatim.
  @default_compaction_window 40
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
    tool_retention: @default_tool_retention,
    compaction_window: @default_compaction_window,
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
  unknown keys. String keys naming a known field are accepted (so a config can be rebuilt
  from a persistence adapter that round-trips settings as JSON).
  """
  @config_fields ~w(model system_prompt tools hooks stream_transformer working_budget
                    injection_reserve tool_retention compaction_window default_timeout
                    hook_timeout audit? persistence notifier pubsub)a
  @field_strings Map.new(@config_fields, &{Atom.to_string(&1), &1})

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> atomize_known_keys()
    validate_model!(Map.get(attrs, :model))

    config = struct!(__MODULE__, attrs)
    validate_positive!(:working_budget, config.working_budget)
    validate_positive!(:injection_reserve, config.injection_reserve)
    validate_positive!(:compaction_window, config.compaction_window)
    validate_positive!(:default_timeout, config.default_timeout)
    validate_positive!(:hook_timeout, config.hook_timeout)
    validate_retention!(config.tool_retention)
    validate_transformer!(config.stream_transformer)
    config
  end

  # Revival from the Ecto adapter hands settings back as a **string-keyed** JSON map; the
  # ETS adapter hands them back atom-keyed. Convert string keys that name a known field to
  # the atom; a string key that isn't a field stays a string and `struct!/2` raises on it
  # (preserving the "unknown keys raise" contract).
  defp atomize_known_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {Map.get(@field_strings, k, k), v}
    end)
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

  defp validate_retention!(%{mode: mode, value: value})
       when mode in [:age, :count] and is_integer(value) and value > 0, do: :ok

  defp validate_retention!(other) do
    raise ArgumentError,
          "tool_retention must be %{mode: :age | :count, value: pos_integer, " <>
            "never_evict: boolean}, got: #{inspect(other)}"
  end

  defp validate_transformer!(nil), do: :ok
  defp validate_transformer!(fun) when is_function(fun, 1), do: :ok

  defp validate_transformer!(other) do
    raise ArgumentError,
          "stream_transformer must be nil or a 1-arity (chunk -> chunk) function, " <>
            "got: #{inspect(other)}"
  end
end
