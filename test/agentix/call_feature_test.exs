defmodule Agentix.CallFeatureTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Event
  alias Agentix.Events.Publisher
  alias Agentix.Hook
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias Agentix.Test.PausingProvider
  alias Agentix.Tool
  alias ReqLLM.Context

  setup do
    install_mock_provider()
    id = "feature-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    on_exit(fn -> Conversation.stop(id) end)
    {:ok, id: id}
  end

  defp config(opts \\ []) do
    Config.new(
      Keyword.merge(
        [model: "mock:test", model_call_log: :records, feature: "chat", retry: false],
        opts
      )
    )
  end

  test "turn features do not change the conversation label or later turns", %{id: id} do
    for feature <- ["view_generation", "space_configuration", :default] do
      MockProvider.script(completion("done"))
      opts = if feature == :default, do: [], else: [feature: feature]
      assert :ok = Conversation.send_message(id, "go", Scope.new(), [config: config()] ++ opts)
      assert_receive {:turn_completed, _}
    end

    assert Enum.map(Persistence.model_calls(id), & &1.feature) == [
             "view_generation",
             "space_configuration",
             "chat"
           ]

    assert Persistence.get_conversation(id).feature == "chat"
  end

  test "a hook selects each call and its override does not leak into the next call", %{id: id} do
    hook =
      Hook.pre(:purpose, fn turn ->
        tool_results = Enum.count(turn.context.messages, &(&1.role == :tool))

        case tool_results do
          0 -> {:cont, Hook.put_feature(turn, "view_generation")}
          1 -> {:cont, Hook.put_feature(turn, "space_configuration")}
          _ -> {:cont, turn}
        end
      end)

    tool = Tool.new(name: "step", executor: :server, callback: fn _, _ -> {:ok, "done"} end)

    MockProvider.script([
      completion("", tool_calls: [{"step", %{}}]),
      completion("", tool_calls: [{"step", %{}}]),
      completion("done")
    ])

    assert :ok =
             Conversation.send_message(id, "go", Scope.new(),
               config: config(hooks: [hook], tools: [tool]),
               feature: "answer"
             )

    assert_receive {:turn_completed, _}, 1_000

    assert Enum.map(Persistence.model_calls(id), & &1.feature) == [
             "view_generation",
             "space_configuration",
             "answer"
           ]
  end

  test "retries keep the selected feature without running the hook again", %{id: id} do
    test_pid = self()

    hook =
      Hook.pre(:purpose, fn turn ->
        send(test_pid, :selected_feature)
        {:cont, Hook.put_feature(turn, "view_generation")}
      end)

    MockProvider.script([error(503), completion("done")])
    retry = %{max_attempts: 2, base_ms: 1, max_ms: 1}

    assert :ok =
             Conversation.send_message(id, "go", Scope.new(),
               config: config(hooks: [hook], retry: retry)
             )

    assert_receive {:turn_completed, _}, 1_000
    assert_received :selected_feature
    refute_received :selected_feature

    assert [
             %{feature: "view_generation", status: :error},
             %{feature: "view_generation", status: :ok}
           ] = Persistence.model_calls(id)
  end

  test "terminal failure records the turn feature", %{id: id} do
    MockProvider.script(error(400))

    assert :ok =
             Conversation.send_message(id, "go", Scope.new(),
               config: config(),
               feature: "view_generation"
             )

    assert_receive {:turn_failed, _, _}
    assert [%{feature: "view_generation", status: :error}] = Persistence.model_calls(id)
  end

  test "cancellation records the feature selected before dispatch", %{id: id} do
    Application.put_env(:agentix, :provider, PausingProvider)
    Application.put_env(:agentix, :pausing_provider, %{text: "partial", test_pid: self()})
    on_exit(fn -> Application.delete_env(:agentix, :pausing_provider) end)

    assert :ok =
             Conversation.send_message(id, "go", Scope.new(),
               config: config(),
               feature: "view_generation"
             )

    assert_receive {:agentix_streaming, task_pid}
    assert Persistence.get_conversation(id).fsm_state.feature == "view_generation"
    assert :ok = Conversation.cancel(id)
    send(task_pid, :agentix_release)
    assert [%{feature: "view_generation", status: :cancelled}] = Persistence.model_calls(id)
  end

  test "recovery restores the dispatched call feature independently of its turn default", %{id: id} do
    Persistence.put_conversation(id, %{settings: Map.from_struct(config())})

    content = %{
      "message" => Jason.decode!(Codec.encode!(Context.user("go"))),
      "feature" => "answer"
    }

    {:ok, seq} = Persistence.append_event(id, Event.new(:user_msg, content, conversation_id: id))

    Persistence.put_fsm_state(id, %{
      state: :idle,
      pending: %{},
      last_seq: seq,
      feature: "view_generation",
      turn_feature: "answer"
    })

    MockProvider.script(completion("done"))

    assert {:ok, _} = Conversation.ensure_started(id)
    assert_receive {:turn_completed, _}
    assert [%{feature: "view_generation"}] = Persistence.model_calls(id)
  end

  test "a stale snapshot does not replace a newly recorded turn feature", %{id: id} do
    Persistence.put_conversation(id, %{settings: Map.from_struct(config())})

    Persistence.put_fsm_state(id, %{
      state: :idle,
      pending: %{},
      last_seq: 0,
      feature: "old",
      turn_feature: "old"
    })

    content = %{"message" => Jason.decode!(Codec.encode!(Context.user("go"))), "feature" => "new"}
    {:ok, _} = Persistence.append_event(id, Event.new(:user_msg, content, conversation_id: id))
    MockProvider.script(completion("done"))
    assert {:ok, _} = Conversation.ensure_started(id)
    assert_receive {:turn_completed, _}
    assert [%{feature: "new"}] = Persistence.model_calls(id)
  end

  test "recovery hooks cannot relabel a call that already reached dispatch", %{id: id} do
    test_pid = self()

    hook =
      Hook.pre(:purpose, fn turn ->
        send(test_pid, {:recovery_hook_ran, turn.scope.system?})
        {:cont, Hook.put_feature(turn, "system_recovery")}
      end)

    tool = Tool.new(name: "step", executor: :server, callback: fn _, _ -> {:ok, "done"} end)

    Persistence.put_conversation(id, %{
      settings: Map.from_struct(config(hooks: [hook], tools: [tool]))
    })

    content = %{
      "message" => Jason.decode!(Codec.encode!(Context.user("go"))),
      "feature" => "answer"
    }

    {:ok, seq} = Persistence.append_event(id, Event.new(:user_msg, content, conversation_id: id))

    Persistence.put_fsm_state(id, %{
      state: :idle,
      pending: %{},
      last_seq: seq,
      feature: "view_generation",
      turn_feature: "answer"
    })

    MockProvider.script([completion("", tool_calls: [{"step", %{}}]), completion("done")])

    assert {:ok, _} = Conversation.ensure_started(id)
    assert_receive {:turn_completed, _}
    assert_received {:recovery_hook_ran, true}

    assert [%{feature: "view_generation"}, %{feature: "system_recovery"}] =
             Persistence.model_calls(id)
  end

  test "recovery after a completed tool-result tail stays idle and a new turn has a fresh feature",
       %{id: id} do
    Persistence.put_conversation(id, %{settings: Map.from_struct(config())})

    content = %{
      "message" => Jason.decode!(Codec.encode!(Context.user("go"))),
      "feature" => "answer"
    }

    {:ok, user_seq} =
      Persistence.append_event(id, Event.new(:user_msg, content, conversation_id: id))

    call = %{"tool_call_id" => "call-completed", "name" => "step", "args" => %{}}
    {:ok, _} = Persistence.append_event(id, Event.new(:tool_call, call, conversation_id: id))
    result = %{"tool_call_id" => "call-completed", "name" => "step", "result" => %{ok: true}}
    {:ok, _} = Persistence.append_event(id, Event.new(:tool_result, result, conversation_id: id))

    Persistence.put_fsm_state(id, %{
      state: :idle,
      pending: %{},
      last_seq: user_seq,
      feature: "view_generation",
      turn_feature: "answer"
    })

    assert {:ok, _} = Conversation.ensure_started(id)
    assert Agentix.Agent.snapshot(id).state == :idle
    assert MockProvider.requests() == []

    MockProvider.script(completion("done"))
    assert :ok = Conversation.send_message(id, "next", Scope.new(), feature: "space_configuration")
    assert_receive {:turn_completed, _}
    assert [%{feature: "space_configuration"}] = Persistence.model_calls(id)
  end

  test "a suspended turn keeps its default after stop and resolution", %{id: id} do
    hook =
      Hook.pre(:purpose, fn turn ->
        if Enum.any?(turn.context.messages, &(&1.role == :tool)),
          do: {:cont, turn},
          else: {:cont, Hook.put_feature(turn, "ask_user")}
      end)

    tool = Tool.new(name: "ask", executor: :human)
    MockProvider.script([completion("", tool_calls: [{"ask", %{}}]), completion("done")])

    assert :ok =
             Conversation.send_message(id, "go", Scope.new(),
               config: config(hooks: [hook], tools: [tool]),
               feature: "view_generation"
             )

    assert_receive {:suspended, call_id, :human, _}
    assert :ok = Conversation.stop(id)
    wait_for_unregister(id)
    assert :ok = Agentix.resolve(id, call_id, "yes")
    assert_receive {:turn_completed, _}
    assert Enum.map(Persistence.model_calls(id), & &1.feature) == ["ask_user", "view_generation"]
  end

  test "invalid turn labels fail before dispatch", %{id: id} do
    for feature <- ["", " \t\n", 1, String.duplicate("a", 256)] do
      assert_raise ArgumentError, fn ->
        Conversation.send_message(id, "go", Scope.new(), config: config(), feature: feature)
      end
    end

    assert MockProvider.requests() == []
    assert Persistence.get_conversation(id) == nil
  end

  test "summary feature has a distinct default and rejects invalid labels" do
    assert config().summary_feature == "conversation_summary"

    for feature <- [nil, "", " \t\n", 1, String.duplicate("a", 256)] do
      assert_raise ArgumentError, fn -> config(summary_feature: feature) end
    end
  end

  test "an invalid hook label halts before dispatch", %{id: id} do
    hook = Hook.pre(:purpose, fn turn -> {:cont, %{turn | feature: ""}} end)
    assert :ok = Conversation.send_message(id, "go", Scope.new(), config: config(hooks: [hook]))
    assert_receive {:turn_halted, _, {:hook_crashed, _}}
    assert MockProvider.requests() == []
    assert Persistence.model_calls(id) == []
  end

  defp wait_for_unregister(id) do
    deadline = System.monotonic_time(:millisecond) + ExUnit.configuration()[:assert_receive_timeout]
    wait_for_unregister(id, deadline)
  end

  defp wait_for_unregister(id, deadline) do
    if Agentix.Addressing.whereis(id) != :error do
      assert System.monotonic_time(:millisecond) < deadline, "agent did not unregister"
      Process.sleep(1)
      wait_for_unregister(id, deadline)
    end
  end
end
