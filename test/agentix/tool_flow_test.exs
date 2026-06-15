defmodule Agentix.ToolFlowTest.ScriptProvider do
  @moduledoc false
  # Pops a prebuilt %ReqLLM.Message{} per stream call — lets a test inject a
  # raw/malformed tool call the scriptable mock can't express.
  @behaviour Agentix.Provider

  def start_link(messages), do: Agent.start_link(fn -> messages end, name: __MODULE__)

  @impl true
  def stream(_model, _context, _opts) do
    message = Agent.get_and_update(__MODULE__, fn [h | t] -> {h, t} end)

    {:ok,
     %Agentix.Provider.Stream{chunks: [], cancel: fn -> :ok end, finalize: fn -> {message, %{}} end}}
  end
end

defmodule Agentix.ToolFlowTest do
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
  alias Agentix.ToolFlowTest.ScriptProvider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(tools, opts \\ []) do
    Config.new(Keyword.merge([model: "mock:test", tools: tools], opts))
  end

  defp final_assistant_text(id) do
    id
    |> Persistence.stream_events()
    |> Enum.filter(&(&1.type == :assistant_msg))
    |> List.last()
    |> then(fn e -> Codec.decode_message(e.content["message"]) end)
    |> Map.fetch!(:content)
    |> Enum.map_join("", & &1.text)
  end

  defp tool_result(id, name) do
    id
    |> Persistence.stream_events()
    |> Enum.find(&(&1.type == :tool_result and &1.content["name"] == name))
    |> then(& &1.content["result"])
  end

  describe ":server executor (resolve in-process)" do
    test "runs the callback and feeds the result back into a second model call", %{id: id} do
      weather =
        Tool.new(
          name: "weather",
          executor: :server,
          callback: fn args, _turn -> {:ok, "sunny in #{args["city"]}"} end
        )

      MockProvider.script([
        completion("", tool_calls: [{"weather", %{"city" => "SF"}}]),
        completion("It is sunny.")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([weather]))
      :ok = Conversation.send_message(id, "weather?", Scope.new())

      assert_receive {:tool_call_started, _tid, "weather", :server, %{"city" => "SF"}}
      assert_receive {:tool_call_resolved, _tid, %{ok: true}}
      assert_receive {:turn_completed, _ref}

      assert_tool_called(id, "weather")
      assert tool_result(id, "weather") == %{ok: true, result: "sunny in SF"}
      assert final_assistant_text(id) == "It is sunny."
    end

    test "tool messages reach the model clean; UI metadata stays on the history path only",
         %{id: id} do
      weather =
        Tool.new(
          name: "weather",
          executor: :server,
          callback: fn args, _turn -> {:ok, "sunny in #{args["city"]}"} end
        )

      MockProvider.script([
        completion("", tool_calls: [{"weather", %{"city" => "SF"}}]),
        completion("It is sunny.")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([weather]))
      :ok = Conversation.send_message(id, "weather?", Scope.new())
      assert_receive {:turn_completed, _ref}

      # The second model call carries the prior turn back to the provider. NO message in
      # that context may carry Agentix's internal metadata — the OpenAI-format encoder
      # serializes `Message.metadata` verbatim onto the wire. This covers the tool row's
      # `tool_name`/`tool_status` AND the assistant row's `id`/`status` bookkeeping.
      internal_keys = ~w(id status tool_name tool_status)
      second_call = Enum.at(MockProvider.requests(), 1)

      assert Enum.find(second_call.context.messages, &(&1.role == :tool)),
             "expected a tool message in the follow-up model context"

      for msg <- second_call.context.messages, key <- internal_keys do
        refute Map.has_key?(msg.metadata || %{}, key),
               "internal metadata #{inspect(key)} leaked to the model on a #{msg.role} message"
      end

      # The UI path (history/snapshot) keeps the metadata so components can render: a
      # named tool card, and a stable per-message stream id.
      ui = Agentix.Agent.history(id).messages
      ui_tool = Enum.find(ui, &(&1.role == :tool))
      assert ui_tool.metadata["tool_name"] == "weather"
      assert ui_tool.metadata["tool_status"] == "ok"
      assert Enum.find(ui, &(&1.role == :assistant)).metadata["id"]
    end
  end

  describe ":provider executor (pass-through, in-process)" do
    test "resolves without suspending and continues the turn", %{id: id} do
      search = Tool.new(name: "search", executor: :provider)

      MockProvider.script([
        completion("", tool_calls: [{"search", %{}}]),
        completion("found it")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([search]))
      :ok = Conversation.send_message(id, "go", Scope.new())

      assert_receive {:tool_call_resolved, _tid, %{ok: true}}
      assert_receive {:turn_completed, _ref}
      refute_received {:suspended, _, _, _}
      assert final_assistant_text(id) == "found it"
    end
  end

  describe ":human executor (suspend → resolve)" do
    test "suspends into awaiting_input with a persisted pending entry, then resumes", %{id: id} do
      ask = Tool.new(name: "ask", executor: :human)

      MockProvider.script([
        completion("", tool_calls: [{"ask", %{"prompt" => "name?"}}]),
        completion("Hi Bob")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([ask]))
      :ok = Conversation.send_message(id, "greet", Scope.new())

      assert_receive {:suspended, tid, :human, %{kind: :elicitation}}
      assert_receive {:state_changed, :awaiting_input}
      assert_suspended_on(id, "ask")

      assert :ok = Agentix.resolve(id, tid, "Bob")
      assert_receive {:turn_completed, _ref}
      assert tool_result(id, "ask") == %{ok: true, result: "Bob"}
      assert final_assistant_text(id) == "Hi Bob"
    end

    test "resolve is stale for an unknown id and for an already-resolved id", %{id: id} do
      ask = Tool.new(name: "ask", executor: :human)
      MockProvider.script([completion("", tool_calls: [{"ask", %{}}]), completion("done")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([ask]))
      :ok = Conversation.send_message(id, "q", Scope.new())
      assert_receive {:suspended, tid, :human, _}

      assert {:error, :stale} = Agentix.resolve(id, "bogus", "x")
      assert :ok = Agentix.resolve(id, tid, "answer")
      assert {:error, :stale} = Agentix.resolve(id, tid, "again")
    end
  end

  describe ":client executor (suspend → resolve)" do
    test "suspends as client_exec and resolves with the client's output", %{id: id} do
      geo = Tool.new(name: "geo", executor: :client)
      MockProvider.script([completion("", tool_calls: [{"geo", %{}}]), completion("at 1,2")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([geo]))
      :ok = Conversation.send_message(id, "where", Scope.new())

      assert_receive {:suspended, tid, :client, %{kind: :client_exec}}
      assert :ok = Agentix.resolve(id, tid, %{"lat" => 1, "lng" => 2})
      assert_receive {:turn_completed, _ref}
      assert tool_result(id, "geo") == %{ok: true, result: %{"lat" => 1, "lng" => 2}}
    end
  end

  describe "approval gate" do
    test "gated :server suspends for approval, runs on approve", %{id: id} do
      deploy =
        Tool.new(
          name: "deploy",
          executor: :server,
          approval: :requires_approval,
          callback: fn _a, _t -> {:ok, "shipped"} end
        )

      MockProvider.script([completion("", tool_calls: [{"deploy", %{}}]), completion("ok")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([deploy]))
      :ok = Conversation.send_message(id, "ship it", Scope.new())

      assert_receive {:suspended, tid, :server, %{kind: :approval}}
      assert :ok = Agentix.resolve(id, tid, :approve)
      assert_receive {:turn_completed, _ref}
      assert tool_result(id, "deploy") == %{ok: true, result: "shipped"}
    end

    test "gated :server records an error result on deny (callback never runs)", %{id: id} do
      deploy =
        Tool.new(
          name: "deploy",
          executor: :server,
          approval: :requires_approval,
          callback: fn _a, _t -> raise "should not run" end
        )

      MockProvider.script([completion("", tool_calls: [{"deploy", %{}}]), completion("aborted")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([deploy]))
      :ok = Conversation.send_message(id, "ship it", Scope.new())

      assert_receive {:suspended, tid, :server, %{kind: :approval}}
      assert :ok = Agentix.resolve(id, tid, :deny)
      assert_receive {:turn_completed, _ref}
      assert %{ok: false} = tool_result(id, "deploy")
      assert final_assistant_text(id) == "aborted"
    end

    test "the approver's scope (not the sender's) reaches the dispatched callback", %{id: id} do
      deploy =
        Tool.new(
          name: "whoami",
          executor: :server,
          approval: :requires_approval,
          callback: fn _args, turn -> {:ok, turn.scope.current_user} end
        )

      MockProvider.script([completion("", tool_calls: [{"whoami", %{}}]), completion("done")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([deploy]))
      :ok = Conversation.send_message(id, "go", Scope.new(current_user: "sender"))

      assert_receive {:suspended, tid, :server, %{kind: :approval}}
      assert :ok = Agentix.resolve(id, tid, :approve, Scope.new(current_user: "approver"))
      assert_receive {:turn_completed, _ref}
      assert tool_result(id, "whoami") == %{ok: true, result: "approver"}
    end

    test "gated :client double-suspends: approval, then client exec", %{id: id} do
      geo = Tool.new(name: "geo", executor: :client, approval: :requires_approval)
      MockProvider.script([completion("", tool_calls: [{"geo", %{}}]), completion("located")])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([geo]))
      :ok = Conversation.send_message(id, "where", Scope.new())

      assert_receive {:suspended, tid, :client, %{kind: :approval}}
      assert :ok = Agentix.resolve(id, tid, :approve)
      assert_receive {:suspended, ^tid, :client, %{kind: :client_exec}}
      assert :ok = Agentix.resolve(id, tid, %{"lat" => 9})
      assert_receive {:turn_completed, _ref}
      assert tool_result(id, "geo") == %{ok: true, result: %{"lat" => 9}}
    end
  end

  describe "timeout" do
    test "an unanswered suspending call times out to a tool-error and resumes", %{id: id} do
      ask = Tool.new(name: "ask", executor: :human)

      MockProvider.script([
        completion("", tool_calls: [{"ask", %{}}]),
        completion("gave up")
      ])

      {:ok, _pid} = Conversation.ensure_started(id, config: config([ask], default_timeout: 60))
      :ok = Conversation.send_message(id, "q", Scope.new())

      assert_receive {:suspended, _tid, :human, _}
      assert_receive {:tool_call_errored, _tid, %{ok: false}}, 500
      assert_receive {:turn_completed, _ref}, 500
      assert %{ok: false} = tool_result(id, "ask")
      assert final_assistant_text(id) == "gave up"
    end
  end

  describe "robustness" do
    test "malformed tool arguments record an error result instead of crashing the agent", %{id: id} do
      Application.put_env(:agentix, :provider, ScriptProvider)

      {:ok, _} =
        ScriptProvider.start_link([
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [ToolCall.new("call_bad", "echo", "not json")]
          },
          %Message{role: :assistant, content: [ContentPart.text("recovered")]}
        ])

      {:ok, pid} = Conversation.ensure_started(id, config: config([]))
      :ok = Conversation.send_message(id, "go", Scope.new())

      assert_receive {:tool_call_errored, "call_bad", %{ok: false}}
      assert_receive {:turn_completed, _ref}
      assert Process.alive?(pid)
      assert %{ok: false, error: "invalid tool arguments"} = tool_result(id, "echo")
      assert final_assistant_text(id) == "recovered"
    end

    test "a crashed server tool is resolved to an error and the turn recovers", %{id: id} do
      crash = Tool.new(name: "boom", executor: :server, callback: fn _a, _t -> exit(:kaboom) end)

      MockProvider.script([
        completion("", tool_calls: [{"boom", %{}}]),
        completion("survived")
      ])

      {:ok, pid} = Conversation.ensure_started(id, config: config([crash]))
      :ok = Conversation.send_message(id, "go", Scope.new())

      assert_receive {:tool_call_errored, _tid, %{ok: false}}
      assert_receive {:turn_completed, _ref}
      assert Process.alive?(pid)
      assert %{ok: false} = tool_result(id, "boom")
      assert final_assistant_text(id) == "survived"
    end
  end
end
