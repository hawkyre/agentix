defmodule Agentix.Compaction.Budget do
  @moduledoc """
  The opaque budget value threaded through the compaction reducers.

  Carries the `total` token target and a `caps` map reserved for **per-tier
  sub-limits** (e.g. `%{tool_results: 5_000, dialogue: 20_000}`) — a future feature.
  The point of wrapping a plain integer in a struct now is that adding those
  sub-limits later must **not** change the `reduce(context, budget, state)` signature
  the reducers implement.
  """

  @type tier :: atom()
  @type t :: %__MODULE__{total: non_neg_integer(), caps: %{tier() => non_neg_integer()}}

  @enforce_keys [:total]
  defstruct total: 0, caps: %{}

  @doc "Builds a budget with a `total` token target and optional per-tier `caps`."
  @spec new(non_neg_integer(), %{tier() => non_neg_integer()}) :: t()
  def new(total, caps \\ %{}) when is_integer(total) and total >= 0 and is_map(caps),
    do: %__MODULE__{total: total, caps: caps}

  @doc "The token cap for `tier`, falling back to the overall `total` when unset."
  @spec cap(t(), tier()) :: non_neg_integer()
  def cap(%__MODULE__{caps: caps, total: total}, tier), do: Map.get(caps, tier, total)

  @doc "Whether `token_count` fits within the overall `total`."
  @spec fits?(t(), non_neg_integer()) :: boolean()
  def fits?(%__MODULE__{total: total}, token_count), do: token_count <= total
end
