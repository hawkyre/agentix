defmodule Agentix.PersistenceConformance do
  @moduledoc """
  Shared ExUnit conformance suite that every `Agentix.Persistence` adapter must
  pass, so the ETS and Ecto adapters cannot drift in semantics.

  Use it from an adapter's test module:

      defmodule Agentix.Persistence.ETSTest do
        use Agentix.PersistenceConformance, adapter: Agentix.Persistence.ETS
      end

  The using module may pass `setup:` work of its own (e.g. the Ecto sandbox) via a
  normal `setup` block; this suite only relies on the public behaviour and uses a
  fresh conversation id per test for isolation.
  """

  # A shared ExUnit suite is, by construction, one long quote in `__using__` —
  # the tests must be injected into the using module. The long-quote-block check
  # does not apply to this pattern.
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  defmacro __using__(opts) do
    quote location: :keep do
      use ExUnit.Case, async: false

      alias Agentix.Event

      @adapter unquote(Keyword.fetch!(opts, :adapter))

      defp uid(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

      defp wait_until(fun, timeout_ms \\ 1_000) do
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        do_wait(fun, deadline)
      end

      defp do_wait(fun, deadline) do
        cond do
          fun.() ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("condition not met before timeout")

          true ->
            Process.sleep(5) && do_wait(fun, deadline)
        end
      end

      test "append assigns ascending per-conversation seq and reads in order" do
        conv = uid("conv")
        {:ok, s1} = @adapter.append_event(conv, Event.new(:user_msg, %{n: 1}))
        {:ok, s2} = @adapter.append_event(conv, Event.new(:assistant_msg, %{n: 2}))

        assert {s1, s2} == {1, 2}
        events = @adapter.stream_events(conv)
        assert Enum.map(events, & &1.seq) == [1, 2]
        assert Enum.map(events, & &1.type) == [:user_msg, :assistant_msg]
        assert Enum.map(events, & &1.content) == [%{n: 1}, %{n: 2}]
        assert Enum.all?(events, &(&1.conversation_id == conv))
      end

      test "stream_events :after filters by seq" do
        conv = uid("conv")
        for n <- 1..3, do: @adapter.append_event(conv, Event.new(:user_msg, %{n: n}))
        assert conv |> @adapter.stream_events(after: 1) |> Enum.map(& &1.seq) == [2, 3]
      end

      test "load_since returns all events when there is no summary" do
        conv = uid("conv")
        {:ok, _} = @adapter.append_event(conv, Event.new(:user_msg, %{n: 1}))
        assert {nil, [%Event{seq: 1}]} = @adapter.load_since(conv)
      end

      test "load_since returns the latest summary and only events after its span" do
        conv = uid("conv")
        for n <- 1..3, do: @adapter.append_event(conv, Event.new(:user_msg, %{n: n}))

        :ok =
          @adapter.put_summary(conv, %{
            from_seq: 1,
            to_seq: 2,
            content: %{"t" => "sum"},
            version: "v1"
          })

        {summary, events} = @adapter.load_since(conv)
        assert summary.to_seq == 2
        assert Enum.map(events, & &1.seq) == [3]
      end

      test "fsm_state round-trips through put_fsm_state/get_conversation" do
        conv = uid("conv")
        fsm = %{state: :awaiting_input, pending: %{"call_1" => %{executor: :human}}, last_seq: 4}
        :ok = @adapter.put_fsm_state(conv, fsm)
        assert @adapter.get_conversation(conv).fsm_state == fsm
      end

      test "get_conversation returns nil for an unknown conversation" do
        assert @adapter.get_conversation(uid("missing")) == nil
      end

      test "tool call upsert, pending listing, and stale-safe resolve" do
        conv = uid("conv")
        tcid = uid("call")

        :ok =
          @adapter.upsert_tool_call(conv, %{id: tcid, executor: :human, args: %{"q" => "city?"}})

        assert [%{id: ^tcid, status: :pending}] = @adapter.pending_tool_calls(conv)

        assert :ok = @adapter.resolve_tool_call(tcid, :resolved, %{ok: true, result: "SF"})
        resolved = @adapter.get_tool_call(tcid)
        assert resolved.status == :resolved
        assert resolved.result == %{ok: true, result: "SF"}
        assert @adapter.pending_tool_calls(conv) == []

        assert {:error, :stale} = @adapter.resolve_tool_call(tcid, :resolved, %{ok: true})
      end

      test "resolve_tool_call on an unknown id is stale" do
        assert {:error, :stale} = @adapter.resolve_tool_call(uid("nope"), :resolved, %{})
      end

      test "latest_summary returns the greatest to_seq" do
        conv = uid("conv")
        :ok = @adapter.put_summary(conv, %{from_seq: 1, to_seq: 10, content: %{}, version: "v1"})
        :ok = @adapter.put_summary(conv, %{from_seq: 11, to_seq: 25, content: %{}, version: "v1"})
        assert @adapter.latest_summary(conv).to_seq == 25
      end

      test "schedule_expiry resolves a still-pending call to a tool-error" do
        conv = uid("conv")
        tcid = uid("call")
        :ok = @adapter.upsert_tool_call(conv, %{id: tcid, executor: :human})
        :ok = @adapter.schedule_expiry(conv, tcid, 20)

        wait_until(fn -> @adapter.get_tool_call(tcid).status == :expired end)

        assert @adapter.get_tool_call(tcid).result == %{
                 ok: false,
                 error: "tool call expired: no response"
               }
      end

      test "cancel_expiry prevents the expiry from firing" do
        conv = uid("conv")
        tcid = uid("call")
        :ok = @adapter.upsert_tool_call(conv, %{id: tcid, executor: :human})
        :ok = @adapter.schedule_expiry(conv, tcid, 50)
        :ok = @adapter.cancel_expiry(conv, tcid)

        Process.sleep(80)
        assert @adapter.get_tool_call(tcid).status == :pending
      end

      test "model_calls are not stored when audit is off" do
        conv = uid("conv")
        :ok = @adapter.put_model_call(conv, %{turn_ref: 1, rendered_context: %{}})
        assert @adapter.model_calls(conv) == []
      end

      test "model_calls are stored when audit is on, and gc removes them" do
        conv = uid("conv")

        Application.put_env(:agentix, :audit, true)

        try do
          :ok = @adapter.put_model_call(conv, %{turn_ref: 1, rendered_context: %{"a" => 1}})
          assert [%{turn_ref: 1}] = @adapter.model_calls(conv)
          assert {:ok, 1} = @adapter.gc_model_calls(conv, 0)
          assert @adapter.model_calls(conv) == []
        after
          Application.delete_env(:agentix, :audit)
        end
      end
    end
  end
end
