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
    * `retry` — transient-failure retry policy for the **pre-stream** provider call
      (`%{max_attempts: pos_integer, base_ms: pos_integer, max_ms: pos_integer}`, or
      `false` to disable). Exponential backoff with jitter, honoring `retry-after`;
      retried error classes are connection drops, HTTP 429, and HTTP 5xx. A failure
      after the first streamed chunk is never retried (no duplicate output). `false`
      and `%{max_attempts: 1}` are equivalent — one attempt, no retry.
    * `response_format` — default output schema applied to every turn that does not
      pass a per-turn `:schema` (`nil` = plain text; a NimbleOptions keyword or a JSON
      Schema map otherwise). A per-turn `schema: false` opts out of this default for
      one turn.
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
          retry:
            %{max_attempts: pos_integer(), base_ms: pos_integer(), max_ms: pos_integer()} | false,
          response_format: keyword() | map() | nil,
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
  # Default retry policy: 3 attempts, exponential backoff 500ms → capped at 8s.
  @default_retry %{max_attempts: 3, base_ms: 500, max_ms: 8_000}

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
    retry: @default_retry,
    response_format: nil,
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
                    hook_timeout audit? retry response_format persistence notifier pubsub)a
  @field_strings Map.new(@config_fields, &{Atom.to_string(&1), &1})

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> atomize_known_keys() |> normalize_retention() |> normalize_retry()
    validate_model!(Map.get(attrs, :model))

    config = struct!(__MODULE__, attrs)
    validate_positive!(:working_budget, config.working_budget)
    validate_positive!(:injection_reserve, config.injection_reserve)
    validate_positive!(:compaction_window, config.compaction_window)
    validate_positive!(:default_timeout, config.default_timeout)
    validate_positive!(:hook_timeout, config.hook_timeout)
    validate_retention!(config.tool_retention)
    validate_transformer!(config.stream_transformer)
    validate_retry!(config.retry)
    validate_response_format!(config.response_format)
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

  # `tool_retention` is a nested map; a JSON round-trip (Ecto) makes its keys and the
  # `:mode` value strings. Rebuild it atom-keyed (idempotent for the atom-keyed forms ETS
  # and direct callers pass) so `validate_retention!/1` matches. Absent → struct default.
  defp normalize_retention(%{tool_retention: %{} = retention} = attrs) do
    %{
      attrs
      | tool_retention: %{
          mode: atomize(retention["mode"] || retention[:mode]),
          value: retention["value"] || retention[:value],
          never_evict: retention["never_evict"] || retention[:never_evict] || false
        }
    }
  end

  defp normalize_retention(attrs), do: attrs

  # `retry` is `false` or a fixed-shape int map; a JSON round-trip (Ecto) makes its keys
  # strings. Rebuild it atom-keyed, merging partial maps with the default so callers may
  # pass just the fields they want to override. Idempotent for the atom-keyed forms.
  defp normalize_retry(%{retry: false} = attrs), do: attrs

  defp normalize_retry(%{retry: %{} = retry} = attrs) do
    %{
      attrs
      | retry: %{
          max_attempts:
            retry["max_attempts"] || retry[:max_attempts] || @default_retry.max_attempts,
          base_ms: retry["base_ms"] || retry[:base_ms] || @default_retry.base_ms,
          max_ms: retry["max_ms"] || retry[:max_ms] || @default_retry.max_ms
        }
    }
  end

  defp normalize_retry(attrs), do: attrs

  defp atomize(value) when is_binary(value), do: String.to_existing_atom(value)
  defp atomize(value), do: value

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

  # `false` disables retry (equivalent to max_attempts: 1). Otherwise all three knobs
  # must be positive ints, with max_ms ≥ base_ms (the cap can't sit below the base delay).
  defp validate_retry!(false), do: :ok

  defp validate_retry!(%{max_attempts: a, base_ms: b, max_ms: m})
       when is_integer(a) and a > 0 and is_integer(b) and b > 0 and is_integer(m) and m >= b,
       do: :ok

  defp validate_retry!(other) do
    raise ArgumentError,
          "retry must be false or %{max_attempts: pos_integer, base_ms: pos_integer, " <>
            "max_ms: pos_integer (>= base_ms)}, got: #{inspect(other)}"
  end

  # `nil` = plain text (no structured output). Otherwise a non-empty NimbleOptions keyword
  # or a JSON Schema map; the schema content itself is opaque here (validated by the provider).
  defp validate_response_format!(nil), do: :ok
  defp validate_response_format!(format) when is_map(format) and map_size(format) > 0, do: :ok

  defp validate_response_format!(format) when is_list(format) and format != [] do
    if Keyword.keyword?(format) do
      :ok
    else
      raise ArgumentError,
            "response_format list must be a NimbleOptions keyword, got: #{inspect(format)}"
    end
  end

  defp validate_response_format!(other) do
    raise ArgumentError,
          "response_format must be nil, a non-empty keyword, or a non-empty map, " <>
            "got: #{inspect(other)}"
  end
end
