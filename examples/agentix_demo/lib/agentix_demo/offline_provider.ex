defmodule AgentixDemo.OfflineProvider do
  @moduledoc false
  # An `Agentix.Provider` that needs no API key, so `mix phx.server` runs out of the box.
  # Streams a canned reply word-by-word (real streaming UX, deterministic, offline). Unlike
  # `Agentix.Test.MockProvider` this has **no ExUnit dependency**, so it is safe as a runtime
  # provider. Selected by `AgentixDemo.ModelConfig` when `ANTHROPIC_API_KEY` is unset.
  @behaviour Agentix.Provider

  alias Agentix.Provider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk

  @impl Provider
  def stream(_model, %ReqLLM.Context{} = context, _opts) do
    reply = canned_reply(context)

    # Word-by-word chunks so the live-streaming UI is exercised offline.
    chunks =
      reply
      |> String.split(~r/(?<= )/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&StreamChunk.text/1)

    message = %Message{role: :assistant, content: [ContentPart.text(reply)]}

    {:ok,
     %Provider.Stream{
       chunks: chunks,
       cancel: fn -> :ok end,
       finalize: fn -> {message, %{input_tokens: 0, output_tokens: 0}} end
     }}
  end

  defp canned_reply(context) do
    case last_user_text(context) do
      nil ->
        "Hi! This is the **offline demo provider** — set `ANTHROPIC_API_KEY` for real model replies."

      text ->
        "You said: *#{text}*.\n\nThis is the **offline demo provider** (no API key set). " <>
          "It echoes your message so the streaming UI works without a model. " <>
          "Export `ANTHROPIC_API_KEY` and restart for real Claude responses."
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
