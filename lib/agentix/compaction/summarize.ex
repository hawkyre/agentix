defmodule Agentix.Compaction.Summarize do
  @moduledoc """
  The only model-calling, lossy, expensive compaction reducer (Inc 8) — kept off the
  critical path.

  It runs **asynchronously between turns** (`start/2` from the agent at turn end, only
  when the free reducers left the context over budget), never blocking the next user
  turn. It collapses the **oldest** turns (prefix-ward) into a single, growing
  front summary and writes a derived `summaries` row. Assembly (`load_since`) then
  reads "latest summary + verbatim tail"; a revived agent reconstructs from log +
  summaries with no `compacting` state — compaction stays out of suspend/resume.

  The summary is **cumulative**: each pass folds the previous summary plus the newly
  collapsed turns into one summary covering `[1, to_seq]`, leaving the last
  `@keep_turns` turns verbatim. Splitting on turn boundaries keeps every
  `tool_call`/`tool_result` pair on the same side — no orphans.
  """

  alias Agentix.Codec
  alias Agentix.Event
  alias Agentix.Persistence
  alias Agentix.Provider
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @version "sum-v1"
  # Turns left verbatim after the front summary (the byte-stable tail).
  @keep_turns 2

  @instruction "Summarize the earlier conversation concisely, preserving key facts, " <>
                 "decisions, entities, and unresolved threads. This summary replaces " <>
                 "the omitted messages, so it must stand on its own."

  @doc """
  Spawns the summarization off the critical path (a `TaskSupervisor` child). Derived
  work — if the agent or task dies, the next over-budget turn simply retries.
  """
  @spec start(String.t(), struct()) :: DynamicSupervisor.on_start_child()
  def start(conversation_id, config) do
    Task.Supervisor.start_child(Agentix.TaskSupervisor, fn -> run(conversation_id, config) end)
  end

  @doc false
  @spec run(String.t(), struct()) :: :ok
  def run(conversation_id, config) do
    {prev_summary, events} = Persistence.load_since(conversation_id)

    case earlier_turns(events) do
      [] ->
        :ok

      to_summarize ->
        to_seq = to_summarize |> List.last() |> Map.fetch!(:seq)
        write_summary(conversation_id, config, prev_summary, to_summarize, to_seq)
    end
  end

  # Everything except the last `@keep_turns` turns (turn boundary = a :user_msg).
  defp earlier_turns(events) do
    turns = chunk_turns(events)

    case length(turns) - @keep_turns do
      collapse when collapse > 0 -> turns |> Enum.take(collapse) |> List.flatten()
      _ -> []
    end
  end

  defp chunk_turns([]), do: []

  defp chunk_turns([first | rest]) do
    {tail, remaining} = Enum.split_while(rest, &(not user_event?(&1)))
    [[first | tail] | chunk_turns(remaining)]
  end

  defp user_event?(%Event{type: :user_msg}), do: true
  defp user_event?(_event), do: false

  defp write_summary(conversation_id, config, prev_summary, events, to_seq) do
    body = [prior_text(prev_summary) | Enum.map(events, &event_text/1)]

    case generate(Enum.join(body, "\n"), config) do
      nil ->
        :ok

      text ->
        message = %Message{role: :system, content: [ContentPart.text(text)]}

        Persistence.put_summary(conversation_id, %{
          from_seq: 1,
          to_seq: to_seq,
          content: %{"message" => Jason.decode!(Codec.encode!(message))},
          version: @version
        })

        :ok
    end
  end

  defp generate(body, config) do
    context = Context.new([Context.system(@instruction), Context.user(body)])

    case Provider.stream(config.model, context, []) do
      {:ok, stream} ->
        Enum.each(stream.chunks, fn _chunk -> :ok end)
        {message, _usage} = stream.finalize.()
        message_text(message)

      {:error, _reason} ->
        nil
    end
  end

  defp prior_text(nil), do: ""

  defp prior_text(summary) do
    summary
    |> summary_message()
    |> message_text()
  end

  defp summary_message(summary) do
    content = summary[:content] || summary["content"]
    Codec.decode_message(content["message"] || content[:message])
  end

  defp event_text(%Event{type: type, content: content}) when type in [:user_msg, :assistant_msg] do
    content
    |> message_map()
    |> Codec.decode_message()
    |> message_text()
  end

  defp event_text(%Event{type: :tool_result, content: content}),
    do: "[tool result] " <> inspect(content["result"] || content[:result])

  defp event_text(_event), do: ""

  defp message_map(content), do: content["message"] || content[:message]

  defp message_text(%Message{content: parts}), do: Enum.map_join(parts, " ", &part_text/1)

  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(_part), do: ""
end
