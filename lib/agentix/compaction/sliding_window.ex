defmodule Agentix.Compaction.SlidingWindow do
  @moduledoc false
  # Caps the dialogue tail to the last `compaction_window` turns.

  alias Agentix.Compaction.State
  alias ReqLLM.Context
  alias ReqLLM.Message

  @doc "Keeps the leading prefix and the last `compaction_window` turns."
  @spec reduce(Context.t(), term(), State.t()) :: {Context.t(), State.t()}
  def reduce(%Context{messages: messages} = context, _budget, %State{config: config} = state) do
    {prefix, turns} = split_turns(messages)
    kept = Enum.take(turns, -config.compaction_window)
    {%{context | messages: prefix ++ Enum.concat(kept)}, state}
  end

  # The prefix is the leading run of non-user messages (system/summary); the rest
  # chunks into turns, each beginning at a user message.
  defp split_turns(messages) do
    {prefix, rest} = Enum.split_while(messages, &(not user?(&1)))
    {prefix, chunk_turns(rest)}
  end

  defp chunk_turns([]), do: []

  defp chunk_turns([%Message{} = user | rest]) do
    {tail, remaining} = Enum.split_while(rest, &(not user?(&1)))
    [[user | tail] | chunk_turns(remaining)]
  end

  defp user?(%Message{role: :user}), do: true
  defp user?(_message), do: false
end
