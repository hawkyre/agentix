defmodule Agentix.Provider do
  @moduledoc """
  Behaviour for streaming an LLM completion, plus the normalized stream handle the
  agent consumes.

  Two implementations: a ReqLLM-backed adapter (the default, added with the agent
  loop) and the scriptable `Agentix.Test.MockProvider` for deterministic,
  key-free tests. The handle is defined from the ReqLLM `StreamResponse` shape so
  the real adapter is a thin wrapper: a lazy stream of chunks, a cancel closure,
  and a finalizer for the assembled message + usage (available only after the
  stream is fully consumed).

  Configure with `config :agentix, :provider, MyProvider`.
  """

  defmodule Stream do
    @moduledoc """
    A normalized streaming handle.

      * `chunks` — an `Enumerable` of `ReqLLM.StreamChunk` (`:content` / `:thinking`
        / `:tool_call` / `:meta`) the agent forwards as live deltas.
      * `cancel` — a 0-arity closure that aborts the stream and frees resources.
      * `finalize` — a 0-arity closure returning `{assembled_message, usage}`; call
        it **after** `chunks` has been fully consumed.
    """

    @enforce_keys [:chunks, :cancel, :finalize]
    defstruct [:chunks, :cancel, :finalize]

    @type t :: %__MODULE__{
            chunks: Enumerable.t(),
            cancel: (-> :ok),
            finalize: (-> {ReqLLM.Message.t(), map()})
          }
  end

  @doc """
  Starts a streaming completion for `model` over `context`. Returns `{:ok,
  %Stream{}}` or `{:error, reason}`. The caller consumes `chunks` fully, may call
  `cancel.()` to abort, and calls `finalize.()` after consumption.
  """
  @callback stream(model :: term(), context :: ReqLLM.Context.t(), opts :: keyword()) ::
              {:ok, Stream.t()} | {:error, term()}

  @default_impl Agentix.Provider.ReqLLM

  @doc "The configured provider implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:agentix, :provider, @default_impl)

  @doc "Streams a completion via the configured provider."
  @spec stream(term(), ReqLLM.Context.t(), keyword()) :: {:ok, Stream.t()} | {:error, term()}
  def stream(model, context, opts \\ []), do: impl().stream(model, context, opts)
end
