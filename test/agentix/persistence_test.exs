defmodule Agentix.PersistenceTest.LegacyAdapter do
  @moduledoc false

  alias Agentix.Persistence.ETS

  defdelegate put_model_call(conversation_id, model_call), to: ETS
  defdelegate model_calls(conversation_id), to: ETS
end

defmodule Agentix.PersistenceTest do
  use ExUnit.Case, async: false

  alias Agentix.Persistence
  alias Agentix.Persistence.ETS
  alias Agentix.PersistenceTest.LegacyAdapter

  setup do
    previous = Application.fetch_env(:agentix, :persistence)
    Application.put_env(:agentix, :persistence, LegacyAdapter)
    id = "legacy-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    on_exit(fn ->
      ETS.delete_conversation(id)

      case previous do
        {:ok, adapter} -> Application.put_env(:agentix, :persistence, adapter)
        :error -> Application.delete_env(:agentix, :persistence)
      end
    end)

    {:ok, id: id}
  end

  test "legacy adapters retain concurrent appends after existing references", %{id: id} do
    refute function_exported?(LegacyAdapter, :append_model_call, 2)
    :ok = Persistence.put_model_call(id, %{turn_ref: 8, model: "existing"})
    :ok = Persistence.put_model_call(id, %{turn_ref: 2, model: "earlier"})
    models = ["summary", "retry", "response"]

    tasks =
      Enum.map(models, fn model ->
        Task.async(fn ->
          receive do
            :append -> Persistence.append_model_call(id, %{model: model})
          end
        end)
      end)

    Enum.each(tasks, fn task -> send(task.pid, :append) end)
    assert Enum.map(tasks, &Task.await/1) == Enum.map(models, fn _ -> :ok end)

    assert [earlier, existing | appended] = Persistence.model_calls(id)
    assert earlier.turn_ref == 2
    assert earlier.model == "earlier"
    assert existing.turn_ref == 8
    assert existing.model == "existing"

    assert Enum.map(appended, & &1.turn_ref) ==
             Enum.to_list((existing.turn_ref + 1)..(existing.turn_ref + length(models)))

    assert Enum.sort(Enum.map(appended, & &1.model)) == Enum.sort(models)
  end
end
