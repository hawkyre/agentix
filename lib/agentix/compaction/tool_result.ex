defmodule Agentix.Compaction.ToolResult do
  @moduledoc false
  # Tool-result retention — stubs expired tool results to shrink the fattest target in

  alias Agentix.Compaction.State
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @stub "[result expired]"

  @doc "Stubs expired tool-result messages in place. See the module doc."
  @spec reduce(Context.t(), term(), State.t()) :: {Context.t(), State.t()}
  def reduce(%Context{messages: messages} = context, _budget, %State{config: config} = state) do
    names = tool_call_names(messages)

    {reversed, _counters} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], %{users: 0, per_tool: %{}}}, fn message, {out, counters} ->
        name = result_tool_name(message, names)
        message = maybe_stub(message, name, counters, config)
        {[message | out], bump(message, name, counters)}
      end)

    {%{context | messages: reversed}, state}
  end

  # tool_call_id => tool name, harvested from the assistant messages' tool_calls.
  defp tool_call_names(messages) do
    for %Message{tool_calls: calls} when is_list(calls) <- messages,
        %{id: id, function: fun} <- calls,
        into: %{},
        do: {id, fun["name"] || fun[:name]}
  end

  defp result_tool_name(%Message{role: :tool, tool_call_id: id}, names), do: Map.get(names, id)
  defp result_tool_name(_message, _names), do: nil

  # `counters` holds, for the messages *after* this one (we fold from the end):
  # `users` = turns elapsed since, `per_tool[name]` = same-tool results since.
  defp maybe_stub(%Message{role: :tool} = message, name, counters, config) do
    if expired?(retention_for(config, name), counters.users, Map.get(counters.per_tool, name, 0)) do
      %{message | content: [ContentPart.text(@stub)]}
    else
      message
    end
  end

  defp maybe_stub(message, _name, _counters, _config), do: message

  defp bump(%Message{role: :user}, _name, counters), do: %{counters | users: counters.users + 1}

  defp bump(%Message{role: :tool}, name, counters),
    do: %{counters | per_tool: Map.update(counters.per_tool, name, 1, &(&1 + 1))}

  defp bump(_message, _name, counters), do: counters

  defp retention_for(config, name) do
    tool = Enum.find(config.tools, &(&1.name == name))
    (tool && tool.retention) || config.tool_retention
  end

  defp expired?(%{never_evict: true}, _age, _count), do: false
  defp expired?(%{mode: :age, value: keep}, age, _count), do: age >= keep
  defp expired?(%{mode: :count, value: keep}, _age, count), do: count >= keep
  defp expired?(_retention, _age, _count), do: false
end
