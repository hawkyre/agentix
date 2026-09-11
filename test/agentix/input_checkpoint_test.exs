defmodule Agentix.InputCheckpointTest.Provider do
  @moduledoc false
  @behaviour Agentix.Provider

  @impl true
  def stream(_model, context, _opts) do
    send(
      Application.fetch_env!(:agentix, :input_checkpoint_test),
      {:model_request, self(), context}
    )

    receive do
      {:respond, message} ->
        {:ok,
         %Agentix.Provider.Stream{
           chunks: [],
           cancel: fn -> :ok end,
           finalize: fn -> {message, %{}} end
         }}
    end
  end
end

defmodule Agentix.InputCheckpointTest.FailingStore do
  @moduledoc false
  alias Agentix.Persistence.ETS

  def append_event(_id, %{content: %{"input_receipt" => %{"source_id" => "fail"}}}),
    do: {:error, :unavailable}

  def append_event(id, %{content: %{"input_receipt" => %{"source_id" => "ambiguous"}}} = event) do
    result = ETS.append_event(id, event)

    if !Process.get({__MODULE__, id}) do
      Process.put({__MODULE__, id}, true)
      raise "lost acknowledgement"
    end

    result
  end

  def append_event(id, event), do: ETS.append_event(id, event)
  defdelegate get_conversation(id), to: ETS
  defdelegate put_conversation(id, attrs), to: ETS
  defdelegate load_since(id), to: ETS
  defdelegate stream_events(id, opts), to: ETS
  defdelegate pending_tool_calls(id), to: ETS
  defdelegate put_fsm_state(id, state), to: ETS
end

defmodule Agentix.InputCheckpointTest do
  use ExUnit.Case, async: false

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.InputAdmission
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.SourceInput
  alias Agentix.Tool
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.ToolCall

  setup do
    previous = Application.get_env(:agentix, :provider)
    Application.put_env(:agentix, :provider, __MODULE__.Provider)
    Application.put_env(:agentix, :input_checkpoint_test, self())
    id = "checkpoint-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, queue} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Conversation.stop(id)
      restore_env(:provider, previous)
      Application.delete_env(:agentix, :input_checkpoint_test)
    end)

    source = fn checkpoint ->
      send(self_test(), {:checkpoint, checkpoint})
      Agent.get(queue, &{:ok, &1})
    end

    %{id: id, queue: queue, config: Config.new(model: "mock:test", input_source: source)}
  end

  test "admits text at no-tool completion and keeps the turn open", %{
    id: id,
    queue: queue,
    config: config
  } do
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:turn_started, ref}
    assert_receive {:model_request, first, _context}
    Agent.update(queue, fn _ -> [input("second", 2)] end)
    send(first, {:respond, Context.assistant("old answer")})

    assert_receive {:input_admitted, ^ref, receipt}
    assert receipt["source_id"] == "second"
    assert Enum.any?(Persistence.stream_events(id), &(&1.seq == receipt["event_sequence"]))
    assert_receive {:model_request, second, context}
    assert Enum.map(context.messages, &message_text/1) == ["first", "old answer", "second"]
    refute_receive {:turn_completed, _ref}
    send(second, {:respond, Context.assistant("new answer")})
    assert_receive {:turn_completed, ^ref}
    refute_receive {:turn_started, _ref}
    assert [^receipt] = Agentix.Agent.snapshot(id).input_receipts
    assert [^receipt] = Agentix.Agent.history(id).input_receipts
  end

  test "waits for every tool in a parallel batch", %{id: id, queue: queue, config: config} do
    test_pid = self()

    tool =
      Tool.new(
        name: "read",
        executor: :server,
        callback: fn args, _turn ->
          send(test_pid, {:tool_running, self(), args["item"]})

          receive do
            :release -> {:ok, args["item"]}
          end
        end
      )

    :ok = Conversation.send_message(id, "first", Scope.new(), config: %{config | tools: [tool]})
    assert_receive {:model_request, model, _context}

    send(
      model,
      {:respond,
       %Message{
         role: :assistant,
         content: [],
         tool_calls: [
           ToolCall.new("call-a", "read", ~s({"item":"a"})),
           ToolCall.new("call-b", "read", ~s({"item":"b"}))
         ]
       }}
    )

    assert_receive {:tool_running, first, "a"}
    assert_receive {:tool_running, second, "b"}
    Agent.update(queue, fn _ -> [input("correction", 1)] end)
    send(first, :release)
    assert_receive {:tool_call_resolved, "call-a", _result}
    refute_receive {:input_admitted, _ref, _receipt}
    send(second, :release)
    assert_receive {:input_admitted, _ref, _receipt}
    assert_receive {:model_request, final, context}
    assert message_text(List.last(context.messages)) == "correction"
    assert Enum.count(context.messages, &(&1.role == :tool)) == 2
    send(final, {:respond, Context.assistant("done")})
    assert_receive {:turn_completed, _ref}
  end

  test "restores receipts across a stopped agent without duplicate admission", %{
    id: id,
    queue: queue,
    config: config
  } do
    Agent.update(queue, fn _ -> [input("stored", 1), input("stored", 1)] end)
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:input_admitted, _ref, receipt}
    assert_receive {:model_request, model, _context}
    send(model, {:respond, Context.assistant("done")})
    assert_receive {:turn_completed, _ref}
    :ok = Conversation.stop(id)

    :ok = Conversation.send_message(id, "next", Scope.new(), config: config)
    assert_receive {:model_request, next, _context}
    send(next, {:respond, Context.assistant("done again")})
    assert_receive {:turn_completed, _ref}
    refute_receive {:input_admitted, _ref, _receipt}
    assert [^receipt] = Agentix.Agent.snapshot(id).input_receipts
  end

  test "source errors terminate explicitly before a provider call", %{id: id, config: config} do
    config = %{config | input_source: fn _ -> {:error, :unavailable} end}
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:turn_failed, _ref, {:input_source, :unavailable}}
    refute_receive {:model_request, _pid, _context}
    assert Agentix.Agent.snapshot(id).state == :idle
  end

  test "source exceptions do not expose exception data", %{id: id, config: config} do
    config = %{config | input_source: fn _ -> raise "private source data" end}
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:turn_failed, _ref, {:input_source, :exception}}
    assert Agentix.Agent.snapshot(id).state == :idle
  end

  test "rejects malformed batches before admitting any input" do
    source = fn _ -> {:ok, [input("a", 2), input("b", 1)]} end

    assert {:error, {:input_source, :invalid_sequence}} =
             InputAdmission.fetch(source, InputAdmission.checkpoint("id", []))

    source = fn _ -> {:ok, [%{input("a", 1) | message: Context.system("bad")}]} end

    assert {:error, {:input_source, :invalid_input}} =
             InputAdmission.fetch(source, InputAdmission.checkpoint("id", []))
  end

  test "config rejects invalid callbacks" do
    assert_raise ArgumentError, fn -> Config.new(model: "mock:test", input_source: :invalid) end
  end

  test "partial store failure keeps durable admissions and emits no false receipt", %{
    id: id,
    queue: queue,
    config: config
  } do
    previous = Application.get_env(:agentix, :persistence)
    Application.put_env(:agentix, :persistence, __MODULE__.FailingStore)
    on_exit(fn -> restore_env(:persistence, previous) end)
    Agent.update(queue, fn _ -> [input("accepted", 1), input("fail", 2)] end)
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:input_admitted, ref, receipt}
    assert receipt["source_id"] == "accepted"
    assert_receive {:turn_failed, ^ref, {:input_source, :persistence_failed}}
    refute_receive {:input_admitted, _ref, _receipt}
    refute_receive {:model_request, _pid, _context}
    assert [^receipt] = Agentix.Agent.snapshot(id).input_receipts
  end

  test "reloads receipts after a committed write loses its acknowledgement", %{
    id: id,
    queue: queue,
    config: config
  } do
    previous = Application.get_env(:agentix, :persistence)
    Application.put_env(:agentix, :persistence, __MODULE__.FailingStore)
    on_exit(fn -> restore_env(:persistence, previous) end)
    Agent.update(queue, fn _ -> [input("ambiguous", 1)] end)
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:turn_failed, _ref, {:input_source, :persistence_failed}}
    refute_receive {:input_admitted, _ref, _receipt}
    :ok = Conversation.send_message(id, "retry", Scope.new())
    assert_receive {:model_request, model, _context}
    send(model, {:respond, Context.assistant("done")})
    assert_receive {:turn_completed, _ref}
    assert [%{"source_id" => "ambiguous"}] = Agentix.Agent.snapshot(id).input_receipts
  end

  test "restores admission after a crash before the provider response", %{
    id: id,
    queue: queue,
    config: config
  } do
    Agent.update(queue, fn _ -> [input("stored", 1)] end)
    {:ok, pid} = Conversation.ensure_started(id, config: config)
    :ok = Conversation.send_message(id, "first", Scope.new())
    assert_receive {:input_admitted, _ref, receipt}
    assert_receive {:model_request, first, _context}
    Process.exit(pid, :kill)
    send(first, {:respond, Context.assistant("lost")})
    assert_receive {:model_request, recovered, context}
    assert Enum.count(context.messages, &(message_text(&1) == "stored")) == 1
    send(recovered, {:respond, Context.assistant("recovered")})
    assert_receive {:turn_completed, _ref}
    refute_receive {:input_admitted, _ref, _receipt}
    assert [^receipt] = Agentix.Agent.snapshot(id).input_receipts
  end

  test "restores receipts outside the summary context window", %{
    id: id,
    queue: queue,
    config: config
  } do
    Agent.update(queue, fn _ -> [input("stored", 1)] end)
    :ok = Conversation.send_message(id, "first", Scope.new(), config: config)
    assert_receive {:input_admitted, _ref, receipt}
    assert_receive {:model_request, first, _context}
    send(first, {:respond, Context.assistant("done")})
    assert_receive {:turn_completed, _ref}
    Conversation.stop(id)

    Persistence.put_summary(id, %{
      from_seq: 1,
      to_seq: receipt["event_sequence"],
      version: "test",
      content: %{
        "message" => "summary" |> Context.system() |> Agentix.Codec.encode!() |> Jason.decode!()
      }
    })

    {_summary, recent} = Persistence.load_since(id)
    assert InputAdmission.receipts(recent) == []
    :ok = Conversation.send_message(id, "next", Scope.new(), config: config)
    assert_receive {:model_request, next, context}
    refute Enum.any?(context.messages, &(message_text(&1) == "stored"))
    send(next, {:respond, Context.assistant("done again")})
    assert_receive {:turn_completed, _ref}
    refute_receive {:input_admitted, _ref, _receipt}
    assert [^receipt] = Agentix.Agent.snapshot(id).input_receipts
  end

  defp input(id, sequence),
    do: %SourceInput{
      source_id: id,
      source_sequence: sequence,
      actor: %{"id" => "member-#{sequence}"},
      message: Context.user(id)
    }

  defp self_test, do: Application.fetch_env!(:agentix, :input_checkpoint_test)

  defp restore_env(key, nil), do: Application.delete_env(:agentix, key)
  defp restore_env(key, value), do: Application.put_env(:agentix, key, value)

  defp message_text(message), do: Enum.map_join(message.content, "", & &1.text)
end
