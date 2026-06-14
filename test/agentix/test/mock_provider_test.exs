defmodule Agentix.Test.MockProviderTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Event
  alias Agentix.Persistence
  alias Agentix.Provider
  alias Agentix.Test.MockProvider
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  setup do
    start_supervised!(MockProvider)
    Application.put_env(:agentix, :provider, MockProvider)
    on_exit(fn -> Application.delete_env(:agentix, :provider) end)
    :ok
  end

  defp conv, do: "conv-" <> Integer.to_string(System.unique_integer([:positive]))

  describe "mock provider streaming" do
    test "streams a scripted text completion deterministically" do
      MockProvider.script(completion("Hello there"))
      {:ok, stream} = Provider.stream("mock:model", Context.new([]), [])

      assert [%StreamChunk{type: :content, text: "Hello there"}] = Enum.to_list(stream.chunks)

      {message, usage} = stream.finalize.()
      assert %Message{role: :assistant} = message
      assert [%ContentPart{type: :text, text: "Hello there"}] = message.content
      assert usage == %{}
      assert stream.cancel.() == :ok
    end

    test "streams a scripted tool call" do
      MockProvider.script(completion("", tool_calls: [{"get_weather", %{"city" => "SF"}}]))
      {:ok, stream} = Provider.stream("mock:model", Context.new([]), [])

      assert [%StreamChunk{type: :tool_call, name: "get_weather", arguments: %{"city" => "SF"}}] =
               Enum.to_list(stream.chunks)

      {message, _usage} = stream.finalize.()
      assert [%ToolCall{function: %{name: "get_weather"}}] = message.tool_calls
    end

    test "scripts are consumed FIFO and requests are recorded" do
      MockProvider.script([completion("a"), completion("b")])
      {:ok, s1} = Provider.stream("mock:m", Context.new([]), foo: 1)
      {:ok, s2} = Provider.stream("mock:m", Context.new([]), [])

      assert [%StreamChunk{text: "a"}] = Enum.to_list(s1.chunks)
      assert [%StreamChunk{text: "b"}] = Enum.to_list(s2.chunks)

      assert [%{model: "mock:m", opts: [foo: 1]}, %{model: "mock:m", opts: []}] =
               MockProvider.requests()
    end

    test "an empty script yields an empty completion" do
      {:ok, stream} = Provider.stream("mock:m", Context.new([]), [])
      assert Enum.to_list(stream.chunks) == []
      {message, _usage} = stream.finalize.()
      assert message.content == []
    end
  end

  describe "assertions over the durable log" do
    test "assert_tool_called detects a logged tool_call event" do
      c = conv()

      {:ok, _} =
        Persistence.append_event(
          c,
          Event.new(:tool_call, %{name: "get_weather", tool_call_id: "c1"})
        )

      assert assert_tool_called(c, "get_weather")
      assert_raise ExUnit.AssertionError, fn -> assert_tool_called(c, "send_email") end
    end

    test "assert_suspended_on detects a pending tool call" do
      c = conv()
      :ok = Persistence.upsert_tool_call(c, %{id: "c2", name: "ask_user", executor: :human})

      assert assert_suspended_on(c, "ask_user")
      assert_raise ExUnit.AssertionError, fn -> assert_suspended_on(c, "other_tool") end
    end
  end

  test "install_mock_provider sets the provider and resets gracefully" do
    assert install_mock_provider() == :ok
    assert Provider.impl() == MockProvider
  end
end
