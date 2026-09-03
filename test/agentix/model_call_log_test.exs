defmodule Agentix.ModelCallLogTest do
  @moduledoc """
  What `model_call_log` records, at each level and for each way a provider call
  can end.

  These assert on the durable rows rather than on telemetry, because the two do
  not agree by design: a cancelled call kills the streaming task and so emits no
  terminal span, while the agent still writes a row for it.
  """
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Scope
  alias Agentix.Test.MockProvider
  alias Agentix.Test.PausingProvider

  @tenant "tenant-metering"

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    {:ok, id: id}
  end

  defp config(level, opts \\ []) do
    Config.new(
      [
        model: "anthropic:claude-sonnet-5",
        model_call_log: level,
        tenant_key: @tenant,
        feature: "extraction",
        retry: false
      ] ++ opts
    )
  end

  defp run(id, config) do
    :ok = Conversation.send_message(id, "go", Scope.new(), config: config)
  end

  describe "levels" do
    test "off records nothing", %{id: id} do
      MockProvider.script(completion("hi"))
      run(id, config(:off))
      assert_receive {:turn_completed, _ref}, 1_000

      assert Persistence.model_calls(id) == []
    end

    test "records stores the call and its cost, but not the prompt", %{id: id} do
      MockProvider.script(completion("hi", usage: %{input_tokens: 14, total_cost: 6.8e-5}))
      run(id, config(:records))
      assert_receive {:turn_completed, _ref}, 1_000

      assert [call] = Persistence.model_calls(id)
      assert call.status == :ok
      assert call.rendered_context == nil
      assert call.model == "anthropic:claude-sonnet-5"
      assert call.usage.input_tokens == 14
      assert call.usage.total_cost == 6.8e-5
      assert call.tenant_key == @tenant
      assert call.feature == "extraction"
      assert is_integer(call.latency_ms) and call.latency_ms >= 0
    end

    test "full adds the rendered prompt", %{id: id} do
      MockProvider.script(completion("hi"))
      run(id, config(:full))
      assert_receive {:turn_completed, _ref}, 1_000

      assert [call] = Persistence.model_calls(id)
      assert is_map(call.rendered_context)
    end

    test "the deprecated audit? flag still means full", %{id: id} do
      MockProvider.script(completion("hi"))
      run(id, Config.new(model: "m", audit?: true, retry: false))
      assert_receive {:turn_completed, _ref}, 1_000

      assert [call] = Persistence.model_calls(id)
      assert is_map(call.rendered_context)
    end
  end

  describe "outcomes" do
    test "a failed call is recorded with its reason and no usage", %{id: id} do
      MockProvider.script(error(500, reason: "upstream exploded"))
      run(id, config(:records))
      assert_receive {:turn_failed, _ref, _reason}, 1_000

      assert [call] = Persistence.model_calls(id)
      assert call.status == :error
      assert call.error =~ "upstream exploded"
      assert call.usage == %{}
    end

    test "a cancelled call is recorded, though its span never closes", %{id: id} do
      Application.put_env(:agentix, :provider, PausingProvider)
      Application.put_env(:agentix, :pausing_provider, %{text: "partial", test_pid: self()})
      on_exit(fn -> Application.delete_env(:agentix, :pausing_provider) end)

      run(id, config(:records))
      assert_receive {:agentix_streaming, task_pid}, 1_000

      :ok = Conversation.cancel(id)
      assert_receive {:cancelled, _ref}, 1_000
      send(task_pid, :agentix_release)

      assert [call] = Persistence.model_calls(id)
      assert call.status == :cancelled
      assert call.error == nil
    end
  end

  describe "double counting" do
    test "a second turn records a second call, keeping turn_ref ordered", %{id: id} do
      MockProvider.script(completion("one"))
      run(id, config(:records))
      assert_receive {:turn_completed, _ref}, 1_000

      MockProvider.script(completion("two"))
      run(id, config(:records))
      assert_receive {:turn_completed, _ref}, 1_000

      assert [%{turn_ref: 1}, %{turn_ref: 2}] = Persistence.model_calls(id)
    end

    test "cancelling an idle conversation records nothing", %{id: id} do
      MockProvider.script(completion("hi"))
      run(id, config(:records))
      assert_receive {:turn_completed, _ref}, 1_000

      :ok = Conversation.cancel(id)

      # Still one row: the completed call, not a phantom cancelled one.
      assert [%{status: :ok}] = Persistence.model_calls(id)
    end
  end
end
