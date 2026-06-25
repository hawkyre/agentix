defmodule Agentix.Provider.ReqLLMTest do
  @moduledoc """
  Real-provider streaming test (D10 tier 2). Excluded from the default/CI run; opt
  in with `mix test --include integration` and an API key in the environment
  (e.g. `ANTHROPIC_API_KEY`).
  """
  use ExUnit.Case, async: false

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope

  @moduletag :integration

  setup do
    # Drive the real ReqLLM adapter, not the mock.
    Application.delete_env(:agentix, :provider)
    id = "conv-int-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  test "streams real text deltas and completes the turn", %{id: id} do
    config = Config.new(model: "anthropic:claude-haiku-4-5", system_prompt: "Reply in one word.")
    {:ok, _pid} = Conversation.ensure_started(id, config: config)

    :ok = Conversation.send_message(id, "Say hello.", Scope.new())

    assert_receive {:state_changed, :streaming}, 30_000
    assert_receive {:text_delta, _ref, _msg_id, delta, _seq}, 30_000
    assert is_binary(delta)
    assert_receive {:message_completed, _ref, %ReqLLM.Message{}}, 30_000
    assert_receive {:turn_completed, _ref}, 30_000
  end

  test "cancel closes the socket and records a partial turn", %{id: id} do
    config = Config.new(model: "anthropic:claude-haiku-4-5", system_prompt: "Write a long story.")
    {:ok, _pid} = Conversation.ensure_started(id, config: config)

    :ok = Conversation.send_message(id, "Tell me a very long story.", Scope.new())

    # As soon as the first delta lands the socket is open; cancel must close it.
    assert_receive {:text_delta, _ref, _msg_id, _delta, _seq}, 30_000
    assert :ok = Conversation.cancel(id)
    assert_receive {:cancelled, _ref}, 30_000
    assert_receive {:state_changed, :idle}, 30_000
  end

  test "structured output returns a schema-conforming object in metadata", %{id: id} do
    config = Config.new(model: "anthropic:claude-haiku-4-5")
    {:ok, _pid} = Conversation.ensure_started(id, config: config)

    schema = [
      sentiment: [type: :string, required: true, doc: "positive, negative, or neutral"],
      score: [type: :float, required: true, doc: "confidence 0..1"]
    ]

    # The already-assembled %ReqLLM.Context{} flows in as `messages` — must not raise on
    # normalization in stream_object/4.
    :ok = Conversation.send_message(id, "I love this library!", Scope.new(), schema: schema)

    assert_receive {:message_completed, _ref, %ReqLLM.Message{} = message}, 30_000
    assert_receive {:turn_completed, _ref}, 30_000

    object = Agentix.object(message)
    assert is_map(object)
    assert Map.has_key?(object, "sentiment") or Map.has_key?(object, :sentiment)
  end
end
