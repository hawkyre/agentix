defmodule Agentix.Persistence.EctoAccountingTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Codec
  alias Agentix.Compaction.Summarize
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.EctoCase
  alias Agentix.Test.MockProvider

  @moduletag :postgres

  setup_all do: EctoCase.start!()

  setup do
    install_mock_provider()
    id = "conv-accounting-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    on_exit(fn -> Conversation.stop(id) end)
    {:ok, id: id}
  end

  test "summary usage survives between normal calls in Postgres", %{id: id} do
    summary_usage = %{input_tokens: 14, total_cost: 6.8e-5}
    questions = ["alpha", "bravo", "charlie"]

    responses =
      questions
      |> Enum.with_index(1)
      |> Enum.map(fn {text, tokens} -> completion(text, usage: %{input_tokens: tokens}) end)

    MockProvider.script(
      responses ++
        [
          completion("SUMMARY-OF-EARLIER", usage: summary_usage),
          completion("after summary", usage: %{input_tokens: length(questions) + 1})
        ]
    )

    config = config()
    {:ok, _pid} = Conversation.ensure_started(id, config: config)

    for question <- questions do
      :ok = Conversation.send_message(id, question, Scope.new())
      assert_receive {:turn_completed, _ref}
    end

    assert :ok = Summarize.run(id, config)
    assert %{to_seq: 2, content: %{"message" => message}} = Persistence.latest_summary(id)

    assert Enum.map_join(Codec.decode_message(message).content, "", & &1.text) ==
             "SUMMARY-OF-EARLIER"

    :ok = Conversation.send_message(id, "delta", Scope.new())
    assert_receive {:turn_completed, _ref}

    calls = Persistence.model_calls(id)
    assert Enum.map(calls, & &1.turn_ref) == Enum.to_list(1..(length(questions) + 2))

    assert Enum.map(calls, & &1.usage) == [
             %{"input_tokens" => 1},
             %{"input_tokens" => 2},
             %{"input_tokens" => 3},
             %{"input_tokens" => 14, "total_cost" => 6.8e-5},
             %{"input_tokens" => 4}
           ]

    assert Enum.all?(calls, fn call ->
             call.status == :ok and call.tenant_key == config.tenant_key and
               call.feature == config.feature and call.model == config.model and
               call.rendered_context == nil
           end)

    assert length(MockProvider.requests()) == length(calls)
  end

  test "Postgres retains a failed attempt before its successful retry", %{id: id} do
    usage = %{input_tokens: 14, total_cost: 6.8e-5}
    MockProvider.script([error(503), completion("recovered", usage: usage)])
    config = config(retry: %{max_attempts: 2, base_ms: 1, max_ms: 5})
    {:ok, _pid} = Conversation.ensure_started(id, config: config)

    :ok = Conversation.send_message(id, "Hi", Scope.new())
    assert_receive {:turn_completed, _ref}

    assert [failed, succeeded] = Persistence.model_calls(id)
    assert failed.turn_ref == 1
    assert failed.status == :error
    assert failed.error =~ "503"
    assert failed.usage == %{}
    assert succeeded.turn_ref == 2
    assert succeeded.status == :ok
    assert succeeded.error == nil
    assert succeeded.usage == %{"input_tokens" => 14, "total_cost" => 6.8e-5}

    assert Enum.all?([failed, succeeded], fn call ->
             call.tenant_key == config.tenant_key and call.feature == config.feature and
               call.model == config.model
           end)

    assert length(MockProvider.requests()) == 2
  end

  defp config(opts \\ []) do
    Config.new(
      Keyword.merge(
        [
          model: "mock:test",
          model_call_log: :records,
          tenant_key: "tenant-accounting",
          feature: "extraction"
        ],
        opts
      )
    )
  end
end
