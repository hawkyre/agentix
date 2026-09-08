defmodule Agentix.AddressingTest do
  use ExUnit.Case, async: false

  import Agentix.Test

  alias Agentix.Addressing
  alias Agentix.Conversation
  alias Agentix.Conversation.Config
  alias Agentix.Events.Publisher
  alias Agentix.Scope
  alias Agentix.Test.MockProvider

  setup do
    install_mock_provider()
    id = "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Agentix.PubSub, Publisher.topic(id))
    on_exit(fn -> Conversation.stop(id) end)
    {:ok, id: id}
  end

  defp use_mode(mode) do
    Application.put_env(:agentix, :addressing, mode)
    on_exit(fn -> Application.delete_env(:agentix, :addressing) end)
  end

  defp config, do: Config.new(model: "m", retry: false)

  # Both registries drop a name when they process the agent's DOWN, which lags
  # the synchronous terminate_child.
  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end

  describe "mode/0" do
    test "defaults to local and takes only the two known values" do
      assert Addressing.mode() == :local

      use_mode(:global)
      assert Addressing.mode() == :global

      Application.put_env(:agentix, :addressing, :nonsense)
      assert Addressing.mode() == :local
    end
  end

  for mode <- [:local, :global] do
    describe "under #{mode} addressing" do
      @mode mode

      test "an unstarted conversation resolves to nothing", %{id: id} do
        use_mode(@mode)
        assert Addressing.whereis(id) == :error
      end

      test "a started conversation resolves to its agent", %{id: id} do
        use_mode(@mode)
        assert {:ok, pid} = Conversation.ensure_started(id, config: config())
        assert Addressing.whereis(id) == {:ok, pid}
      end

      test "a second start returns the same agent, never a rival", %{id: id} do
        use_mode(@mode)
        assert {:ok, pid} = Conversation.ensure_started(id, config: config())
        assert {:ok, ^pid} = Conversation.ensure_started(id, config: config())
      end

      test "stopping unregisters the name", %{id: id} do
        use_mode(@mode)
        {:ok, _pid} = Conversation.ensure_started(id, config: config())

        :ok = Conversation.stop(id)

        assert eventually(fn -> Addressing.whereis(id) == :error end)
      end

      test "cancel returns only once the turn is down", %{id: id} do
        use_mode(@mode)
        Application.put_env(:agentix, :provider, Agentix.Test.PausingProvider)
        Application.put_env(:agentix, :pausing_provider, %{text: "partial", test_pid: self()})
        on_exit(fn -> Application.delete_env(:agentix, :pausing_provider) end)

        :ok = Conversation.send_message(id, "go", Scope.new(), config: config())
        assert_receive {:agentix_streaming, task_pid}, 1_000

        assert Conversation.cancel(id) == :ok

        refute Process.alive?(task_pid)
        assert_receive {:cancelled, _ref}, 1_000
      end
    end
  end

  describe "global addressing" do
    test "registers a cluster-visible name, local addressing does not", %{id: id} do
      use_mode(:global)
      {:ok, pid} = Conversation.ensure_started(id, config: config())

      assert :global.whereis_name({Addressing, id}) == pid
    end

    test "a local-mode agent is invisible to global lookup", %{id: id} do
      {:ok, _pid} = Conversation.ensure_started(id, config: config())

      assert :global.whereis_name({Addressing, id}) == :undefined
    end
  end

  describe "cancel with nothing to cancel" do
    test "is a no-op", %{id: id} do
      MockProvider.script(completion("hi"))
      assert Conversation.cancel(id) == :ok
    end
  end
end
