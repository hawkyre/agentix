defmodule Agentix.Compaction do
  @moduledoc """
  Fits the **rendered context** to a token budget. Operates on a projection of the
  log, never the log itself — the log is immutable; compaction shapes a turn's
  context to fit, so replay stays faithful.

  Compaction and pre-message injection are independent; the only thing they share is
  the token budget, applied to the final rendered context. The assembly layout keeps
  the provider prompt cache warm:

      [ stable prefix: system prompt + latest summary ]    ← cached, byte-stable
      [ verbatim history tail (recent messages) ]          ← append-only, byte-stable
      [ per-turn injected content adjacent to the user msg ] ← the only changing region

  A cache breakpoint is marked at the end of the stable prefix; it moves only when a
  new summary is written.

  ## Reducers

  A reducer implements `reduce(context, budget, state) :: {context, state}`, and
  `compact/3` runs the free, deterministic reducers in order. **None are wired into
  the assembly path today**: keeping the rendered tail append-only between turns is
  what makes the prompt cache effective, so per-turn trimming is deliberately
  avoided. `Agentix.Compaction.ToolResult` and `Agentix.Compaction.SlidingWindow`
  remain available (and tested) for a future discrete, boundary-aligned variant.

  The sole context shrink is **summarization** (`Agentix.Compaction.Summarize`): a
  lossy, model-calling reducer that runs asynchronously between turns, only when the
  context is over budget, collapsing the oldest turns prefix-ward into a growing
  front summary. That summary is the one part of the stable prefix that changes — a
  rare, discrete event the cache breakpoint is aligned to. `over_budget?/2` is the
  trigger.
  """

  alias Agentix.Compaction.Budget
  alias Agentix.Compaction.State
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

  # The free, deterministic reducers, run in order by `compact/3`. Empty today — the
  # rendered tail is kept append-only between turns so the prompt cache stays warm;
  # summarization is the sole (discrete, between-turns) context shrink (see moduledoc).
  @free_reducers []

  @doc """
  Runs the free, deterministic reducers over `context` (cheap → expensive), threading
  the budget and per-reducer state, and returns the reduced context. With no free
  reducers wired in, returns `context` unchanged (summarization, off the assembly
  path, does the shrinking).
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
