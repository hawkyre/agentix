defmodule Agentix.Tokenizer do
  @moduledoc """
  Approximate token counting for budgeting the assembled context.

  Exact counts only come back from the provider *after* a call and are
  model-specific; ReqLLM exposes no public count API, so Agentix owns a
  pre-send estimate. This is a **behaviour** with a default
  `Agentix.Tokenizer.Heuristic` (a byte-count estimate). A real tokenizer (a tiktoken NIF, etc.)
  is a later optional adapter behind the same behaviour — selected via
  `config :agentix, :tokenizer, MyTokenizer`.

  Budget conservatively: an over-budget context is a hard provider failure, while
  over-eager compaction is mild waste. Counting covers text content parts (the bulk);
  it intentionally under-counts structured tool-call args, so set `working_budget`
  comfortably below the model window.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message

  @doc "Estimated token count for a string."
  @callback count(String.t()) :: non_neg_integer()

  @doc "The configured tokenizer module (default `Agentix.Tokenizer.Heuristic`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:agentix, :tokenizer, Agentix.Tokenizer.Heuristic)

  @doc "Estimated token count for a string, via the configured tokenizer."
  @spec count(String.t()) :: non_neg_integer()
  def count(text) when is_binary(text), do: impl().count(text)

  @doc "Estimated token count for an assembled context (sum over message text parts)."
  @spec count_context(Context.t()) :: non_neg_integer()
  def count_context(%Context{messages: messages}),
    do: Enum.reduce(messages, 0, fn message, acc -> acc + count_message(message) end)

  defp count_message(%Message{content: parts}) when is_list(parts),
    do: Enum.reduce(parts, 0, fn part, acc -> acc + count(part_text(part)) end)

  defp count_message(_message), do: 0

  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(_part), do: ""
end
