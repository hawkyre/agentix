defmodule AgentixDemo.OfflineProvider do
  @moduledoc false
  # An `Agentix.Provider` that needs no API key, so `mix phx.server` runs out of the box and
  # still showcases every executor + live reasoning. Unlike `Agentix.Test.MockProvider` it has
  # **no ExUnit dependency**, so it is safe as a runtime provider. Selected by
  # `AgentixDemo.ModelConfig` when `ANTHROPIC_API_KEY` is unset.
  #
  # It "reasons" out loud (a thinking chunk → streamed to the JS hook), then either emits a
  # tool call or streams a text reply: a "test/verify" message → the approval-gated `run_tests`
  # tool, any other question → `search_code`. Once a tool result comes back it folds it into a
  # final answer. (With a real key the live model drives these same tools far better.)
  @behaviour Agentix.Provider

  alias Agentix.Provider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @impl Provider
  def stream(_model, %ReqLLM.Context{} = context, _opts), do: {:ok, to_handle(decide(context))}

  defp decide(%ReqLLM.Context{} = context) do
    cond do
      result = tool_result_text(context) ->
        {:text, "Here's what I found: #{result}",
         "A tool result came back — I'll fold it into a final answer."}

      true ->
        reply_for(last_user_text(context) || "")
    end
  end

  defp reply_for(text) do
    cond do
      text =~ ~r/\b(run|verify|test|tests)\b/i ->
        {:tool, "run_tests", %{"path" => "test/agentix/hook_test.exs"},
         "They want to verify behavior — I'll propose running a test file (needs approval)."}

      text =~ ~r/[a-z]/i ->
        {:tool, "search_code", %{"query" => keyword_in(text)},
         "I'll search the source to ground my answer."}

      true ->
        {:text, canned_reply(text), "A normal message — I'll just reply directly."}
    end
  end

  # A rough search term for offline mode: the longest word in the message (the real model
  # picks far better queries).
  defp keyword_in(text) do
    text
    |> String.split(~r/[^A-Za-z_.]+/, trim: true)
    |> Enum.max_by(&String.length/1, fn -> "hook" end)
  end

  defp to_handle({:text, text, thinking}) do
    chunks = [StreamChunk.thinking(thinking) | word_chunks(text)]
    message = %Message{role: :assistant, content: [ContentPart.text(text)]}
    handle(chunks, message)
  end

  defp to_handle({:tool, name, args, thinking}) do
    chunks = [StreamChunk.thinking(thinking), StreamChunk.tool_call(name, args)]

    message = %Message{
      role: :assistant,
      content: [],
      tool_calls: [ToolCall.new(nil, name, Jason.encode!(args))]
    }

    handle(chunks, message)
  end

  defp handle(chunks, message) do
    %Provider.Stream{
      chunks: chunks,
      cancel: fn -> :ok end,
      finalize: fn -> {message, %{input_tokens: 0, output_tokens: 0}} end
    }
  end

  defp word_chunks(text),
    do:
      text |> String.split(~r/(?<= )/) |> Enum.reject(&(&1 == "")) |> Enum.map(&StreamChunk.text/1)

  defp canned_reply(""),
    do: "Hi! This is the **offline demo provider** — set `ANTHROPIC_API_KEY` for real replies."

  defp canned_reply(text) do
    "You said: *#{text}*.\n\nThis is the **offline demo provider** (no API key set). Set " <>
      "`ANTHROPIC_API_KEY` and restart so the real model can search and read the source."
  end

  defp tool_result_text(%ReqLLM.Context{messages: messages}) do
    case List.last(messages) do
      %Message{role: :tool} = msg -> text_of(msg.content)
      _ -> nil
    end
  end

  defp last_user_text(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :user, content: parts} -> text_of(parts)
      _ -> nil
    end)
  end

  defp text_of(text) when is_binary(text), do: if(text == "", do: nil, else: text)

  defp text_of(parts) when is_list(parts) do
    joined =
      parts
      |> Enum.flat_map(fn
        %{text: t} when is_binary(t) -> [t]
        _ -> []
      end)
      |> Enum.join()

    if joined == "", do: nil, else: joined
  end

  defp text_of(_), do: nil
end
