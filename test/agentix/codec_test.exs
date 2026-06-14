defmodule Agentix.CodecTest do
  use ExUnit.Case, async: true

  alias Agentix.Codec
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.ToolCall

  defp roundtrip(value, decoder) do
    value |> Codec.encode!() |> Jason.decode!() |> decoder.()
  end

  describe "decode_content_part/1 round-trips every variant" do
    test "all ContentPart constructors survive encode→decode" do
      parts = [
        ContentPart.text("hello"),
        ContentPart.text("with meta", %{"k" => "v"}),
        ContentPart.text("unicode: héllo 日本語 🤖"),
        ContentPart.thinking("step-by-step reasoning"),
        ContentPart.image_url("https://example.com/cat.png"),
        ContentPart.video_url("https://example.com/clip.mp4"),
        ContentPart.image(<<0, 1, 2, 250, 255>>, "image/png"),
        ContentPart.file(<<10, 20, 30>>, "report.pdf", "application/pdf"),
        ContentPart.file_id("file_abc123")
      ]

      for part <- parts do
        assert roundtrip(part, &Codec.decode_content_part/1) == part
      end
    end

    test "binary data is restored byte-for-byte (not left base64)" do
      part = ContentPart.image(<<0, 255, 16, 32, 64>>, "image/jpeg")
      decoded = roundtrip(part, &Codec.decode_content_part/1)
      assert decoded.data == <<0, 255, 16, 32, 64>>
    end

    test "raises on an unknown content type" do
      assert_raise ArgumentError, ~r/unknown content part type/, fn ->
        Codec.decode_content_part(%{"type" => "hologram"})
      end
    end
  end

  describe "decode_message/1" do
    test "user message with text content" do
      msg = %Message{role: :user, content: [ContentPart.text("hi")]}
      assert roundtrip(msg, &Codec.decode_message/1) == msg
    end

    test "assistant message with tool calls" do
      msg = %Message{
        role: :assistant,
        content: [ContentPart.text("let me check")],
        tool_calls: [ToolCall.new("call_1", "get_weather", ~s({"location":"SF"}))]
      }

      decoded = roundtrip(msg, &Codec.decode_message/1)
      assert decoded == msg
      assert [%ToolCall{id: "call_1", function: %{name: "get_weather"}}] = decoded.tool_calls
    end

    test "tool result message keyed by tool_call_id" do
      msg = %Message{
        role: :tool,
        tool_call_id: "call_1",
        content: [ContentPart.text(~s({"ok":true}))]
      }

      assert roundtrip(msg, &Codec.decode_message/1) == msg
    end

    test "message carrying reasoning details" do
      msg = %Message{
        role: :assistant,
        content: [ContentPart.text("answer")],
        reasoning_details: [
          %ReasoningDetails{text: "thinking", signature: "sig", provider: :anthropic, index: 1}
        ]
      }

      assert roundtrip(msg, &Codec.decode_message/1) == msg
    end

    test "empty content and string-keyed metadata" do
      msg = %Message{role: :user, content: [], metadata: %{"source" => "test"}}
      assert roundtrip(msg, &Codec.decode_message/1) == msg
    end

    test "raises on an unknown role" do
      assert_raise ArgumentError, ~r/unknown message role/, fn ->
        Codec.decode_message(%{"role" => "wizard", "content" => []})
      end
    end
  end

  describe "decode_context/1" do
    test "round-trips a multi-message context" do
      context =
        Context.new([
          %Message{role: :system, content: [ContentPart.text("be helpful")]},
          %Message{role: :user, content: [ContentPart.text("hi")]},
          %Message{
            role: :assistant,
            content: [ContentPart.text("hello!")],
            tool_calls: [ToolCall.new("c1", "noop", "{}")]
          }
        ])

      assert roundtrip(context, &Codec.decode_context/1) == context
    end
  end

  describe "golden fixtures (guard against ReqLLM field renames)" do
    test "text content part decodes from canonical JSON" do
      json = """
      {"type":"text","text":"hi","url":null,"data":null,"file_id":null,
       "media_type":null,"filename":null,"metadata":{}}
      """

      assert Codec.decode_content_part(Jason.decode!(json)) == ContentPart.text("hi")
    end

    test "tool call decodes from canonical JSON" do
      json = ~s({"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"}})

      assert %{"role" => "assistant", "tool_calls" => [Jason.decode!(json)]}
             |> Codec.decode_message()
             |> Map.fetch!(:tool_calls) == [ToolCall.new("call_1", "f", "{}")]
    end
  end

  describe "decode error handling" do
    test "an unknown provider raises a clear error" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        Codec.decode_message(%{
          "role" => "assistant",
          "content" => [],
          "reasoning_details" => [%{"provider" => "definitely_not_a_provider"}]
        })
      end
    end

    test "invalid base64 data raises a clear error" do
      assert_raise ArgumentError, ~r/not valid base64/, fn ->
        Codec.decode_content_part(%{"type" => "image", "data" => "!!!not base64!!!"})
      end
    end

    test "a non-list content field raises a clear error" do
      assert_raise ArgumentError, ~r/expected a list or nil/, fn ->
        Codec.decode_message(%{"role" => "user", "content" => "oops"})
      end
    end
  end
end
