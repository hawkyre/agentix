defmodule AgentixDemo.OfflineProvider do
  @moduledoc false
  # An `Agentix.Provider` that needs no API key, so `mix phx.server` runs out of the box and
  # still showcases every executor + live reasoning. Unlike `Agentix.Test.MockProvider` it has
  # **no ExUnit dependency**, so it is safe as a runtime provider. Selected by
  # `AgentixDemo.ModelConfig` when `ANTHROPIC_API_KEY` is unset.
  #
  # It "reasons" out loud (a thinking chunk → streamed to the JS hook), then either streams a
  # text reply or emits a tool call based on the message: "weather …" → the gated `get_weather`
  # server tool, a message with digits → the `calculator` server tool, a bare greeting → the
  # `ask_user` human elicitation. Once a tool result comes back it folds it into a final answer.
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
      tool_result_text(context) ->
        {:text, "Here's what I found: #{tool_result_text(context)}",
         "A tool result came back — I'll fold it into a final answer."}

      true ->
        reply_for(last_user_text(context) || "")
    end
  end

  defp reply_for(text) do
    cond do
      text =~ ~r/weather/i ->
        {:tool, "get_weather", %{"city" => city_in(text)},
         "They're asking about the weather — I'll call get_weather (it needs approval)."}

      text =~ ~r/\d/ ->
        {:tool, "calculator", %{"expression" => text},
         "This looks like arithmetic — I'll run the calculator tool."}

      text =~ ~r/^\s*(hi|hello|hey)\b/i ->
        {:tool, "ask_user", %{},
         "A greeting with no task yet — I'll ask what they'd like help with."}

      true ->
        {:text, canned_reply(text), "A normal message — I'll just reply directly."}
    end
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
    "You said: *#{text}*.\n\nThis is the **offline demo provider** (no API key set). Try " <>
      "\"weather in Tokyo\" for an approval-gated tool, or \"6 * 7\" for the calculator."
  end

  defp city_in(text) do
    case Regex.run(~r/weather\s+(?:in|for)\s+([A-Za-z][A-Za-z .'-]*)/i, text) do
      [_, city] -> String.trim(city)
      _ -> "your area"
    end
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
