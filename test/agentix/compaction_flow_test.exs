defmodule Agentix.CompactionFlowTest.FinalizeFailureProvider do
  @moduledoc false
  @behaviour Agentix.Provider

  alias Agentix.Test.MockProvider

  @impl true
  def stream(model, context, opts) do
    {:ok, stream} = MockProvider.stream(model, context, opts)
    {:ok, %{stream | finalize: fn -> raise "summary finalization failed" end}}
  end
end

defmodule Agentix.CompactionFlowTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Compaction.Summarize
  alias Agentix.CompactionFlowTest.FinalizeFailureProvider
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Event
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias Agentix.Test.PausingProvider
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp msg_content(message), do: %{"message" => Jason.decode!(Codec.encode!(message))}

  defp seed_turn(id, user_text, assistant_text) do
    {:ok, _} = Persistence.append_event(id, user_event(id, user_text))
    {:ok, _} = Persistence.append_event(id, assistant_event(id, assistant_text))
  end

  defp user_event(id, text),
    do: Event.new(:user_msg, msg_content(Context.user(text)), conversation_id: id)

  defp assistant_event(id, text) do
    message = %Message{role: :assistant, content: [ContentPart.text(text)]}
    Event.new(:assistant_msg, msg_content(message), conversation_id: id)
  end

  defp put_summary(id, to_seq, text) do
    message = %Message{role: :system, content: [ContentPart.text(text)]}

    Persistence.put_summary(id, %{
      from_seq: 1,
      to_seq: to_seq,
      content: msg_content(message),
      version: "sum-v1"
    })
  end

  defp request_text do
    %{context: %Context{messages: messages}} = List.last(MockProvider.requests())

    messages
    |> Enum.flat_map(fn %Message{content: parts} -> Enum.map(parts, &(&1.text || "")) end)
    |> Enum.join("\n")
  end

  defp wait_for_summary(id, tries \\ 100) do
    case Persistence.latest_summary(id) do
      nil when tries > 0 -> Process.sleep(10) && wait_for_summary(id, tries - 1)
      summary -> summary
    end
  end

  describe "Summarize.run/2 — prefix-ward cumulative summary row" do
    @tag :accounting_regression
    test "records the summary call and preserves its returned usage", %{id: id} do
      seed_turn(id, "alpha", "resp1")
      seed_turn(id, "bravo", "resp2")
      seed_turn(id, "charlie", "resp3")

      # Use the usage fixture from ModelCallLogTest, not a price estimate.
      usage = %{input_tokens: 14, total_cost: 6.8e-5}
      MockProvider.script(completion("SUMMARY-OF-EARLIER", usage: usage))

      config =
        Config.new(
          model: "mock:test",
          model_call_log: :records,
          tenant_key: "tenant-metering",
          feature: "extraction"
        )

      assert :ok = Summarize.run(id, config)
      assert %{to_seq: 2, content: %{"message" => message}} = Persistence.latest_summary(id)

      assert Enum.map_join(Codec.decode_message(message).content, "", & &1.text) ==
               "SUMMARY-OF-EARLIER"

      assert [_request] = MockProvider.requests()
      assert [call] = Persistence.model_calls(id)
      assert call.status == :ok
      assert call.model == config.model
      assert call.usage == usage
      assert call.tenant_key == config.tenant_key
      assert call.feature == config.feature
      assert call.summary_version == summary_version(id)
      assert call.rendered_context == nil
      assert is_integer(call.latency_ms) and call.latency_ms >= 0
    end

    test "full logging stores the summary prompt", %{id: id} do
      seed_summary_history(id)
      MockProvider.script(completion("summary"))

      assert :ok = Summarize.run(id, config(id, model_call_log: :full))

      assert [request] = MockProvider.requests()
      assert [call] = Persistence.model_calls(id)
      assert call.rendered_context == Jason.decode!(Codec.encode!(request.context))
    end

    test "disabled logging stores the summary without a call record", %{id: id} do
      seed_summary_history(id)
      MockProvider.script(completion("summary"))

      assert :ok = Summarize.run(id, config(id, model_call_log: :off))

      assert Persistence.latest_summary(id)
      assert Persistence.model_calls(id) == []
    end

    test "summary calls use the application logging default", %{id: id} do
      previous = Application.get_env(:agentix, :model_call_log)
      Application.put_env(:agentix, :model_call_log, :records)

      on_exit(fn ->
        if previous do
          Application.put_env(:agentix, :model_call_log, previous)
        else
          Application.delete_env(:agentix, :model_call_log)
        end
      end)

      seed_summary_history(id)
      MockProvider.script(completion("summary"))

      assert :ok = Summarize.run(id, config(id, []))

      assert [%{status: :ok, rendered_context: nil}] = Persistence.model_calls(id)
    end

    test "a failed summary call records the error without reported usage", %{id: id} do
      seed_summary_history(id)
      MockProvider.script(error(503))

      assert :ok = Summarize.run(id, config(id, model_call_log: :records))

      assert Persistence.latest_summary(id) == nil
      assert [call] = Persistence.model_calls(id)
      assert call.status == :error
      assert call.error =~ "503"
      assert call.usage == %{}
    end

    test "summary finalization failure records one error", %{id: id} do
      seed_summary_history(id)
      MockProvider.script(completion("summary"))
      Application.put_env(:agentix, :provider, FinalizeFailureProvider)
      on_exit(fn -> Application.put_env(:agentix, :provider, MockProvider) end)

      assert_raise RuntimeError, "summary finalization failed", fn ->
        Summarize.run(id, config(id, model_call_log: :records))
      end

      assert Persistence.latest_summary(id) == nil
      assert [call] = Persistence.model_calls(id)
      assert call.status == :error
      assert call.error =~ "summary finalization failed"
      assert call.usage == %{}
    end

    test "a summary and a live call keep separate records", %{id: id} do
      seed_summary_history(id)
      Application.put_env(:agentix, :provider, PausingProvider)
      Application.put_env(:agentix, :pausing_provider, %{text: "summary", test_pid: self()})

      on_exit(fn ->
        Application.delete_env(:agentix, :pausing_provider)
        Application.put_env(:agentix, :provider, MockProvider)
      end)

      config = config(id, model_call_log: :records)
      {:ok, _pid} = Conversation.ensure_started(id, config: config)
      summary_task = Task.async(fn -> Summarize.run(id, config) end)
      assert_receive {:agentix_streaming, summary_pid}

      :ok = Conversation.send_message(id, "next", Scope.new())
      assert_receive {:agentix_streaming, call_pid}

      send(summary_pid, :agentix_release)
      assert :ok = Task.await(summary_task)
      send(call_pid, :agentix_release)
      assert_receive {:turn_completed, _ref}

      assert [summary_call, live_call] = Persistence.model_calls(id)
      assert summary_call.summary_version == summary_version(id)
      assert summary_call.status == :ok
      assert live_call.status == :ok
      assert summary_call.turn_ref < live_call.turn_ref
    end

    test "too few turns make no summary call or record", %{id: id} do
      seed_turn(id, "alpha", "resp1")

      assert :ok = Summarize.run(id, config(id, model_call_log: :records))

      assert MockProvider.requests() == []
      assert Persistence.model_calls(id) == []
    end

    test "collapses the oldest turns into a summary, leaving the recent tail", %{id: id} do
      seed_turn(id, "alpha", "resp1")
      seed_turn(id, "bravo", "resp2")
      seed_turn(id, "charlie", "resp3")
      MockProvider.script(completion("SUMMARY-OF-EARLIER"))

      assert :ok = Summarize.run(id, Config.new(model: "mock:test"))

      summary = Persistence.latest_summary(id)
      # 3 turns, keep the last 2 verbatim => collapse turn 1 (seq 1–2).
      assert summary[:to_seq] == 2
      assert summary[:from_seq] == 1
      message = Codec.decode_message(summary[:content]["message"])
      assert Enum.map_join(message.content, "", & &1.text) == "SUMMARY-OF-EARLIER"
    end
  end

  describe "assembly reads latest summary + verbatim tail" do
    test "the summary replaces the summarized span; only later events are verbatim", %{id: id} do
      seed_turn(id, "alpha-q", "alpha-a")
      seed_turn(id, "bravo-q", "bravo-a")
      put_summary(id, 2, "PRIOR-SUMMARY")

      MockProvider.script(completion("ok"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(id, working_budget: 30_000))
      :ok = Conversation.send_message(id, "new-question", Scope.new())
      assert_receive {:turn_completed, _ref}

      text = request_text()
      assert text =~ "PRIOR-SUMMARY"
      assert text =~ "bravo-q"
      assert text =~ "new-question"
      # The summarized first turn is gone from the rendered context.
      refute text =~ "alpha-q"
      refute text =~ "alpha-a"
    end
  end

  describe "over-budget turn triggers async summarization, next assembly reads it" do
    test "summary is written off the critical path and picked up next turn", %{id: id} do
      seed_turn(id, "alpha-" <> pad(), "resp1-" <> pad())
      seed_turn(id, "bravo-" <> pad(), "resp2-" <> pad())

      # Tiny budget: the 3rd turn pushes the rendered context over, triggering
      # prefix-ward summarization between turns.
      MockProvider.script([completion("resp3"), completion("SUMMARY3"), completion("resp4")])

      {:ok, _pid} =
        Conversation.ensure_started(id,
          config: config(id, working_budget: 20, injection_reserve: 1)
        )

      :ok = Conversation.send_message(id, "charlie-" <> pad(), Scope.new())
      assert_receive {:turn_completed, _ref}

      summary = wait_for_summary(id)
      assert summary[:to_seq] == 2

      :ok = Conversation.send_message(id, "delta", Scope.new())
      assert_receive {:turn_completed, _ref}

      text = request_text()
      assert text =~ "SUMMARY3"
      assert text =~ "bravo-"
      refute text =~ "alpha-"
    end
  end

  describe "prompt-cache breakpoint" do
    test "marks the stable-prefix (summary) boundary, byte-stable across turns", %{id: id} do
      seed_turn(id, "alpha-q", "alpha-a")
      seed_turn(id, "bravo-q", "bravo-a")
      put_summary(id, 2, "PRIOR-SUMMARY")

      MockProvider.script([completion("ok-one"), completion("ok-two")])
      {:ok, _pid} = Conversation.ensure_started(id, config: config(id, working_budget: 30_000))

      :ok = Conversation.send_message(id, "q-one", Scope.new())
      assert_receive {:turn_completed, _ref}
      :ok = Conversation.send_message(id, "q-two", Scope.new())
      assert_receive {:turn_completed, _ref}

      [req1, req2] = MockProvider.requests()

      # The summary :system message is the stable-prefix boundary; its last content
      # part carries the cache_control marker.
      boundary = Enum.find(req1.context.messages, &(&1.role == :system))
      assert List.last(boundary.content).metadata[:cache_control] == %{type: "ephemeral"}

      # The marked prefix (everything up to and including the boundary) is byte-stable
      # across the two turns — only the appended tail differs.
      assert system_prefix(req1.context.messages) == system_prefix(req2.context.messages)
    end

    test "no breakpoint when there is no system prompt and no summary", %{id: id} do
      MockProvider.script(completion("ok"))
      {:ok, _pid} = Conversation.ensure_started(id, config: config(id, []))

      :ok = Conversation.send_message(id, "hi", Scope.new())
      assert_receive {:turn_completed, _ref}

      %{context: %Context{messages: messages}} = List.last(MockProvider.requests())
      refute Enum.any?(messages, fn m -> Enum.any?(m.content, & &1.metadata[:cache_control]) end)
    end
  end

  defp system_prefix(messages), do: Enum.take_while(messages, &(&1.role == :system))

  defp seed_summary_history(id) do
    seed_turn(id, "alpha", "resp1")
    seed_turn(id, "bravo", "resp2")
    seed_turn(id, "charlie", "resp3")
  end

  defp summary_version(id), do: Persistence.latest_summary(id).version

  defp config(_id, opts), do: Config.new(Keyword.merge([model: "mock:test"], opts))
  defp pad, do: String.duplicate("x", 48)
end
