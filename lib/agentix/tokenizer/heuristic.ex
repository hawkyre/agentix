defmodule Agentix.Tokenizer.Heuristic do
  @moduledoc """
  The default `Agentix.Tokenizer`: a byte-count estimate (≈ English-text token
  density of ~4 bytes/token) with a deliberate ~20% over-estimate so budgeting errs
  toward leaving headroom — under-counting risks a hard over-window failure, while
  over-counting only compacts a little early. A `+1` floor keeps non-empty text from
  counting as zero. No dependency; rough by design — see `Agentix.Tokenizer`.
  """

  @behaviour Agentix.Tokenizer

  # bytes × 3/10 ≈ bytes/3.33 — about 20% above the bytes/4 baseline (the safety margin).
  @impl true
  def count(text) when is_binary(text), do: div(byte_size(text) * 3, 10) + 1
end
