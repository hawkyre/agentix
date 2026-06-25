defmodule Agentix.StructuredOutputTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias Agentix.Tool

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(opts \\ []), do: Config.new(Keyword.merge([model: "mock:test"], opts))

  describe "per-turn :schema" do
    test "yields a structured object and skips the tool loop even with tools configured", %{id: id} do
      schema = %{sentiment: [type: :string]}
      noop_tool = Tool.new(name: "noop", executor: :server, callback: fn _a, _t -> {:ok, %{}} end)

      # The scripted completion carries BOTH a tool call and an object: the schema turn
      # must be terminal — object surfaced, tool loop skipped.
      MockProvider.script(
        completion("", object: %{"sentiment" => "positive"}, tool_calls: [{"noop", %{}}])
      )

      {:ok, _pid} = Conversation.ensure_started(id, config: config(tools: [noop_tool]))
      :ok = Conversation.send_message(id, "How do I sound?", Scope.new(), schema: schema)

      assert_receive {:message_completed, _ref, message}
      assert_receive {:turn_completed, _ref}
      assert Agentix.object(message) == %{"sentiment" => "positive"}

      # No tool was dispatched despite the message carrying a tool call.
      refute_received {:tool_call_started, _, _, _, _}
      events = Persistence.stream_events(id)
      refute Enum.any?(events, &(&1.type == :tool_call))
    end

    test "schema: false opts out of the config default (plain text, no object)", %{id: id} do
      MockProvider.script(completion("just text"))

      {:ok, _pid} =
        Conversation.ensure_started(id, config: config(response_format: %{a: [type: :string]}))

      :ok = Conversation.send_message(id, "hi", Scope.new(), schema: false)

      assert_receive {:message_completed, _ref, message}
      assert_receive {:turn_completed, _ref}
      assert Agentix.object(message) == nil
      assert message.metadata["object"] == nil
    end

    test "passes the schema through to the provider opts", %{id: id} do
      schema = %{mood: [type: :string]}
      MockProvider.script(completion("x", object: %{"mood" => "ok"}))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "hi", Scope.new(), schema: schema)
      assert_receive {:turn_completed, _ref}

      assert [%{opts: opts}] = MockProvider.requests()
      assert Keyword.get(opts, :schema) == schema
    end
  end

  describe "per-turn :schema validation" do
    test "rejects an invalid schema value at the boundary (raises, no deep crash)", %{id: id} do
      MockProvider.script(completion("x"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      assert_raise ArgumentError, ~r/:schema must be/, fn ->
        Conversation.send_message(id, "hi", Scope.new(), schema: "not a schema")
      end

      assert_raise ArgumentError, fn ->
        Conversation.send_message(id, "hi", Scope.new(), schema: 42)
      end

      assert_raise ArgumentError, fn ->
        Conversation.send_message(id, "hi", Scope.new(), schema: %{})
      end
    end

    test "accepts false and nil as opt-outs without raising", %{id: id} do
      MockProvider.script([completion("a"), completion("b")])
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      assert :ok = Conversation.send_message(id, "hi", Scope.new(), schema: false)
      assert_receive {:turn_completed, _ref}
      assert :ok = Conversation.send_message(id, "hi", Scope.new(), schema: nil)
      assert_receive {:turn_completed, _ref}
    end
  end

  describe "config response_format default" do
    test "applies when no per-turn :schema is given", %{id: id} do
      MockProvider.script(completion("x", object: %{"k" => 1}))

      {:ok, _pid} =
        Conversation.ensure_started(id, config: config(response_format: %{k: [type: :integer]}))

      :ok = Conversation.send_message(id, "hi", Scope.new())
      assert_receive {:message_completed, _ref, message}
      assert Agentix.object(message) == %{"k" => 1}

      assert [%{opts: opts}] = MockProvider.requests()
      assert Keyword.get(opts, :schema) == %{k: [type: :integer]}
    end
  end

  describe "persistence round-trip (V-8)" do
    test "the object survives replay from the durable log", %{id: id} do
      MockProvider.script(completion("x", object: %{"score" => 9, "label" => "good"}))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      :ok = Conversation.send_message(id, "hi", Scope.new(), schema: %{score: [type: :integer]})
      assert_receive {:turn_completed, _ref}

      # Replay the assistant event straight from persistence and decode it.
      assistant =
        id
        |> Persistence.stream_events()
        |> Enum.filter(&(&1.type == :assistant_msg))
        |> List.last()

      message = Codec.decode_message(assistant.content["message"])
      assert Agentix.object(message) == %{"score" => 9, "label" => "good"}
    end
  end

  describe "Chat projection" do
    test "exposes the object via :last_object on a fresh history hydration", %{id: id} do
      MockProvider.script(completion("x", object: %{"v" => 42}))
      {:ok, _pid} = Conversation.ensure_started(id, config: config())
      :ok = Conversation.send_message(id, "hi", Scope.new(), schema: %{v: [type: :integer]})
      assert_receive {:turn_completed, _ref}

      # A fresh snapshot (as a reconnecting LiveView sees) carries the object.
      snapshot = Agentix.Agent.snapshot(id)
      last = snapshot.messages |> Enum.filter(&(&1.role == :assistant)) |> List.last()
      assert Agentix.object(last) == %{"v" => 42}
    end
  end
end
