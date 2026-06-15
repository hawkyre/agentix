defmodule Agentix.Tokenizer.Heuristic do
  @moduledoc """
  The default `Agentix.Tokenizer`: a `char/4` estimate (≈ English-text token
  density) with a `+1` floor so non-empty text never counts as zero. No dependency.
  Deliberately rough and slightly conservative — see `Agentix.Tokenizer`.
  """

  @behaviour Agentix.Tokenizer

  @impl true
  def count(text) when is_binary(text), do: div(byte_size(text), 4) + 1
end
