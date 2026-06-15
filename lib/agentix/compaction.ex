defmodule Agentix.Compaction do
  @moduledoc """
  Fits the **rendered context** to a token budget (Inc 8). Operates on a projection
  of the log, never the log itself — the log is immutable; compaction is how a turn's
  context is shaped to fit, so replay stays faithful.

  Independent of injection (Inc 7); the only shared thing is the token budget,
  applied to the final rendered context. Assembly layout (cache-prefix discipline):

      [ stable prefix: system prompt + latest summary ]   ← cached, byte-stable
      [ verbatim history tail (recent messages) ]          ← byte-stable
      [ per-turn injected content adjacent to the user msg ] ← only changing region

  ## Reducer contract

  A reducer implements `reduce(context, budget, state) :: {context, state}`. The free,
  deterministic reducers run on **every** assembly, cheap → expensive:

    1. `Agentix.Compaction.ToolResult` — stub expired tool results (pairing intact).
    2. `Agentix.Compaction.SlidingWindow` — cap the dialogue tail to a turn window.

  Summarization (`Agentix.Compaction.Summarize`) is the only model-calling, lossy
  reducer; it is **not** in this synchronous pipeline. It runs asynchronously between
  turns (`maybe_summarize/2` at turn end) only when the free reducers leave the
  context over budget, writing a prefix-ward `summaries` row the next assembly reads.
  """

  alias Agentix.Compaction.Budget
  alias Agentix.Compaction.SlidingWindow
  alias Agentix.Compaction.State
  alias Agentix.Compaction.ToolResult
  alias Agentix.Conversation.Config
  alias Agentix.Tokenizer
  alias ReqLLM.Context

  defmodule State do
    @moduledoc false
    # Per-reduction state threaded through the free reducers. Carries the
    # conversation config (retention rules, window size); structured so a reducer can
    # accumulate its own state in future without changing `reduce/3`.
    @type t :: %__MODULE__{config: Config.t()}
    @enforce_keys [:config]
    defstruct [:config]
  end

  @free_reducers [ToolResult, SlidingWindow]

  @doc """
  Runs the free, deterministic reducers over `context` (cheap → expensive), threading
  the budget and per-reducer state. Returns the reduced context.
  """
  @spec compact(Context.t(), Budget.t(), Config.t()) :: Context.t()
  def compact(%Context{} = context, %Budget{} = budget, %Config{} = config) do
    state = %State{config: config}

    {context, _state} =
      Enum.reduce(@free_reducers, {context, state}, fn reducer, {ctx, st} ->
        reducer.reduce(ctx, budget, st)
      end)

    context
  end

  @doc "Whether `context` is still over the budget's total token target."
  @spec over_budget?(Context.t(), Budget.t()) :: boolean()
  def over_budget?(%Context{} = context, %Budget{} = budget),
    do: not Budget.fits?(budget, Tokenizer.count_context(context))
end
