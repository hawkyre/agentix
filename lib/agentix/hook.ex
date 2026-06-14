defmodule Agentix.Hook do
  @moduledoc """
  A hook: a function the agent runs around a model call, plus its metadata.

  Two phases (D7, contracts.md):

    * **`:pre`** — runs in `preparing`, before the model call, on the assembled
      `%Agentix.Turn{}`. Sequential pre-hooks `(turn -> {:cont, turn} | {:halt, reason})`
      can transform the turn (inject context via `inject/2`) or halt it; a `:halt`
      short-circuits the rest of the pipeline and the turn never reaches the model.
      Parallel pre-hooks are **append-only** `(turn -> {:cont, [ContentPart]})`: they
      run concurrently and their parts are appended, in declaration order, at the
      **tail** of the context (cache-prefix safety, D7).
    * **`:post`** — runs after the assistant message finalizes (`:message_completed`),
      on a turn carrying the finalized `assistant_message`. `(turn -> {:cont, turn} |
      {:halt, reason})`; side-effecting in v0.

  ## Injection budget (D7)

  Pre-hook injections are bounded by the conversation's `injection_reserve`. If the
  injected content exceeds it, the pipeline raises `Agentix.Hook.OverflowError`
  naming the offending hook — a loud config error, **not** a trigger for compaction
  (the two subsystems are independent; compaction is never re-entered to make room).

  ## `durable?` (pinned for v0)

  Hook output is **transient** in v0: pre-hook injections ride only the per-model-call
  rendered context (so they reach the optional `model_calls` audit table) and are
  regenerated each assembly — never written to the canonical event log. The
  `durable?` field is part of the contract and is validated, but durable
  log-persistence of hook output (appending it as a normal event) is **deferred** to
  the layer that owns the event-shape/compaction (Inc 8/11): it needs a data-model
  decision (a dedicated event type vs. overloading `:user_msg`) that does not belong
  in the loop. A `durable?: true` hook therefore behaves identically to a transient
  one in v0; consumers must not yet rely on persistence. See inc-7-notes.

  Hooks (and the stream transformer) are functions and are **not** JSON-serializable;
  like tool callbacks they live in the conversation config and are rebuilt from it on
  revival (a no-op for the ETS adapter, which stores terms verbatim).
  """

  alias Agentix.Turn
  alias ReqLLM.Message.ContentPart

  @type phase :: :pre | :post
  @type mode :: :sequential | :parallel

  @type pre_result :: {:cont, Turn.t()} | {:cont, [ContentPart.t()]} | {:halt, term()}
  @type post_result :: {:cont, Turn.t()} | {:halt, term()}

  @type t :: %__MODULE__{
          name: term(),
          phase: phase(),
          mode: mode(),
          durable?: boolean(),
          run: (Turn.t() -> pre_result() | post_result())
        }

  @enforce_keys [:name, :phase, :run]
  defstruct [:name, :phase, :run, mode: :sequential, durable?: false]

  @phases [:pre, :post]
  @modes [:sequential, :parallel]

  @doc """
  Builds a hook from `attrs`. Raises `ArgumentError` on a missing/invalid `:phase`,
  an invalid `:mode`, a non-1-arity `:run`, or a `:parallel` `:post` hook (parallel
  append-only batches only make sense before the model call).
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    hook = struct!(__MODULE__, attrs)
    validate_phase!(hook.phase)
    validate_mode!(hook.mode)
    validate_run!(hook.run)
    validate_phase_mode!(hook.phase, hook.mode)
    hook
  end

  @doc "Builds a `:pre` hook. `opts`: `:mode` (`:sequential`/`:parallel`), `:durable?`."
  @spec pre(term(), (Turn.t() -> pre_result()), keyword()) :: t()
  def pre(name, run, opts \\ []) do
    new([name: name, phase: :pre, run: run] ++ opts)
  end

  @doc "Builds a `:post` hook. `opts`: `:durable?`."
  @spec post(term(), (Turn.t() -> post_result()), keyword()) :: t()
  def post(name, run, opts \\ []) do
    new([name: name, phase: :post, run: run] ++ opts)
  end

  @doc """
  Applies the stream-transformer seam to a chunk. The transformer is `(chunk ->
  chunk)`; `nil` is the identity default. The single declared call site for the
  per-chunk transform (driven from the provider stream).
  """
  @spec transform_chunk(chunk, (chunk -> chunk) | nil) :: chunk when chunk: term()
  def transform_chunk(chunk, nil), do: chunk
  def transform_chunk(chunk, fun) when is_function(fun, 1), do: fun.(chunk)

  @doc """
  Appends content to the turn's pending injections (placed at the context tail at
  assembly time). The append-only primitive sequential pre-hooks use to inject.
  """
  @spec inject(Turn.t(), ContentPart.t() | [ContentPart.t()]) :: Turn.t()
  def inject(%Turn{injections: injections} = turn, parts) when is_list(parts) do
    %{turn | injections: injections ++ parts}
  end

  def inject(%Turn{} = turn, part), do: inject(turn, [part])

  defp validate_phase!(phase) when phase in @phases, do: :ok

  defp validate_phase!(other) do
    raise ArgumentError, "invalid hook phase #{inspect(other)}; expected one of #{inspect(@phases)}"
  end

  defp validate_mode!(mode) when mode in @modes, do: :ok

  defp validate_mode!(other) do
    raise ArgumentError, "invalid hook mode #{inspect(other)}; expected one of #{inspect(@modes)}"
  end

  defp validate_run!(run) when is_function(run, 1), do: :ok

  defp validate_run!(other) do
    raise ArgumentError, "a hook requires a 1-arity :run function, got: #{inspect(other)}"
  end

  defp validate_phase_mode!(:post, :parallel) do
    raise ArgumentError,
          ":parallel is only legal for a :pre hook — parallel append-only batches " <>
            "run before the model call; a :post hook is sequential"
  end

  defp validate_phase_mode!(_phase, _mode), do: :ok
end
