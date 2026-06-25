defmodule Agentix.Compaction do
  @moduledoc false
  # Fits the rendered context to a token budget. Operates on a projection of the

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
