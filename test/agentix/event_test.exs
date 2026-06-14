defmodule Agentix.EventTest do
  use ExUnit.Case, async: true

  alias Agentix.Event

  describe "new/2" do
    test "builds an event for each of the six canonical types" do
      for type <- Event.types() do
        event = Event.new(type, %{foo: "bar"})
        assert %Event{type: ^type, content: %{foo: "bar"}} = event
        assert is_nil(event.seq)
        assert is_nil(event.conversation_id)
        assert is_nil(event.inserted_at)
      end
    end

    test "carries optional persistence metadata when supplied" do
      at = ~U[2026-06-14 00:00:00Z]
      event = Event.new(:user_msg, %{}, seq: 7, conversation_id: "c1", inserted_at: at)
      assert event.seq == 7
      assert event.conversation_id == "c1"
      assert event.inserted_at == at
    end

    test "raises on an invalid type" do
      assert_raise ArgumentError, ~r/invalid event type :nope/, fn ->
        Event.new(:nope, %{})
      end
    end

    test "raises when content is not a map" do
      assert_raise ArgumentError, ~r/content must be a map/, fn ->
        Event.new(:user_msg, "not a map")
      end
    end

    test "raises on mistyped opts" do
      assert_raise ArgumentError, ~r/:seq must be a non-negative integer/, fn ->
        Event.new(:user_msg, %{}, seq: -1)
      end

      assert_raise ArgumentError, ~r/:conversation_id must be a string/, fn ->
        Event.new(:user_msg, %{}, conversation_id: 123)
      end

      assert_raise ArgumentError, ~r/:inserted_at must be a DateTime/, fn ->
        Event.new(:user_msg, %{}, inserted_at: "2026-01-01")
      end
    end
  end

  describe "types/0 and valid_type?/1" do
    test "exposes exactly the six closed types" do
      assert Event.types() == [
               :user_msg,
               :assistant_msg,
               :tool_call,
               :tool_result,
               :suspension,
               :resolution
             ]
    end

    test "valid_type?/1 reflects membership" do
      assert Event.valid_type?(:tool_call)
      refute Event.valid_type?(:tool_started)
    end
  end
end
