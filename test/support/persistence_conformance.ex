defmodule Agentix.PersistenceConformance do
  @moduledoc """
  Shared ExUnit conformance suite that every `Agentix.Persistence` adapter must
  pass, so the ETS and Ecto adapters cannot drift in semantics.

  Use it from an adapter's test module:

      defmodule Agentix.Persistence.ETSTest do
        use Agentix.PersistenceConformance, adapter: Agentix.Persistence.ETS
      end

  Lives in `test/support` (not `lib/`) so the ExUnit-dependent scaffold never ships
  in the released package. The using module may add its own `setup` (e.g. the Ecto
  sandbox); this suite only relies on the public behaviour and uses a fresh
  conversation id per test for isolation. It runs `async: false` — some cases
  mutate global application env.
  """

  # A shared ExUnit suite is, by construction, one long quote in `__using__` — the
  # tests must be injected into the using module. The check does not apply here.
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  defmacro __using__(opts) do
    # `@moduletag` must be set *before* the test macros below run (ExUnit captures a test's
    # tags at definition time), so the caller passes it through the macro rather than after
    # `use` — e.g. `use Agentix.PersistenceConformance, adapter: …, moduletag: :postgres`.
    moduletag_ast =
      case Keyword.get(opts, :moduletag) do
        nil -> nil
        tag -> quote(do: @moduletag(unquote(tag)))
      end

    quote location: :keep do
      use ExUnit.Case, async: false

      alias Agentix.Event

      unquote(moduletag_ast)

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
            Process.sleep(5)
            do_wait(fun, deadline)
        end
      end

      test "append assigns ascending per-conversation seq and reads in order" do
        conv = uid("conv")
        # Event content is asserted with **string keys**: that is its canonical persisted
        # form (the agent writes Codec/JSON output), and the only form a jsonb-backed
        # adapter can round-trip. Both adapters must agree on it.
        {:ok, s1} = @adapter.append_event(conv, Event.new(:user_msg, %{"n" => 1}))
        {:ok, s2} = @adapter.append_event(conv, Event.new(:assistant_msg, %{"n" => 2}))

        assert {s1, s2} == {1, 2}
        events = @adapter.stream_events(conv)
        assert Enum.map(events, & &1.seq) == [1, 2]
        assert Enum.map(events, & &1.type) == [:user_msg, :assistant_msg]
        assert Enum.map(events, & &1.content) == [%{"n" => 1}, %{"n" => 2}]
        assert Enum.all?(events, &(&1.conversation_id == conv))
      end

      test "seq is scoped per conversation (interleaved appends stay independent)" do
        a = uid("conv")
        b = uid("conv")
        {:ok, a1} = @adapter.append_event(a, Event.new(:user_msg, %{}))
        {:ok, b1} = @adapter.append_event(b, Event.new(:user_msg, %{}))
        {:ok, a2} = @adapter.append_event(a, Event.new(:user_msg, %{}))

        assert {a1, a2, b1} == {1, 2, 1}
        assert Enum.map(@adapter.stream_events(b), & &1.seq) == [1]
      end

      test "stream_events :after filters by seq" do
        conv = uid("conv")
        for n <- 1..3, do: @adapter.append_event(conv, Event.new(:user_msg, %{n: n}))
        assert conv |> @adapter.stream_events(after: 1) |> Enum.map(& &1.seq) == [2, 3]
      end

      test "stream_events :before bounds above and :limit keeps the most-recent (tail)" do
        conv = uid("conv")
        for n <- 1..5, do: @adapter.append_event(conv, Event.new(:user_msg, %{n: n}))

        # :before is an exclusive upper bound.
        assert conv |> @adapter.stream_events(before: 3) |> Enum.map(& &1.seq) == [1, 2]
        # :limit keeps the most recent N (the tail), still ascending.
        assert conv |> @adapter.stream_events(limit: 2) |> Enum.map(& &1.seq) == [4, 5]
        # Combined: the newest page below a cursor — backward pagination.
        assert conv |> @adapter.stream_events(before: 4, limit: 2) |> Enum.map(& &1.seq) == [2, 3]
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

      test "pending_tool_calls is scoped to the conversation" do
        a = uid("conv")
        b = uid("conv")
        :ok = @adapter.upsert_tool_call(a, %{id: uid("call"), executor: :human})
        :ok = @adapter.upsert_tool_call(b, %{id: uid("call"), executor: :human})

        assert length(@adapter.pending_tool_calls(a)) == 1
        assert Enum.all?(@adapter.pending_tool_calls(a), &(&1.conversation_id == a))
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

      test "rescheduling expiry does not leak the first timer" do
        conv = uid("conv")
        tcid = uid("call")
        :ok = @adapter.upsert_tool_call(conv, %{id: tcid, executor: :human})
        :ok = @adapter.schedule_expiry(conv, tcid, 20)
        # Reschedule far out; the original 20ms timer must not fire.
        :ok = @adapter.schedule_expiry(conv, tcid, 5_000)

        Process.sleep(80)
        assert @adapter.get_tool_call(tcid).status == :pending
      end

      # Adapters persist what they are handed; whether a call is recorded at all
      # is the agent's decision from `model_call_log`, not the adapter's.
      test "model_calls are stored as given, and gc removes them" do
        conv = uid("conv")

        :ok = @adapter.put_model_call(conv, %{turn_ref: 1, rendered_context: %{"a" => 1}})
        assert [%{turn_ref: 1}] = @adapter.model_calls(conv)
        assert {:ok, 1} = @adapter.gc_model_calls(conv, 0)
        assert @adapter.model_calls(conv) == []
      end

      test "a model_call round-trips every recorded field" do
        conv = uid("conv")
        tenant = uid("tenant")

        :ok =
          @adapter.put_model_call(conv, %{
            turn_ref: 1,
            rendered_context: nil,
            model: "anthropic:claude-sonnet-5",
            usage: %{"input_tokens" => 14, "total_cost" => 6.8e-5},
            latency_ms: 940,
            status: :error,
            error: "provider stream open failed",
            tenant_key: tenant,
            feature: "extraction",
            pricing_version: "2026.8.4"
          })

        assert [call] = @adapter.model_calls(conv)
        assert call.rendered_context == nil
        assert call.model == "anthropic:claude-sonnet-5"
        assert call.usage["total_cost"] == 6.8e-5
        assert call.latency_ms == 940
        assert call.status == :error
        assert call.error == "provider stream open failed"
        assert call.tenant_key == tenant
        assert call.feature == "extraction"
        assert call.pricing_version == "2026.8.4"
      end

      test "delete_conversation removes the row, its events, and its model calls" do
        conv = uid("conv")

        :ok = @adapter.put_conversation(conv, %{settings: %{"a" => 1}})
        {:ok, _seq} = @adapter.append_event(conv, Event.new(:user_msg, %{n: 1}))
        :ok = @adapter.put_model_call(conv, %{turn_ref: 1, rendered_context: %{}})

        :ok = @adapter.delete_conversation(conv)

        assert @adapter.get_conversation(conv) == nil
        assert @adapter.stream_events(conv) == []
        assert @adapter.model_calls(conv) == []

        # Idempotent: deleting an unknown/already-deleted id is still :ok.
        assert @adapter.delete_conversation(conv) == :ok

        # The seq counter reset with the conversation: a fresh append is seq 1.
        {:ok, seq} = @adapter.append_event(conv, Event.new(:user_msg, %{n: 2}))
        assert seq == 1
      end

      test "feature round-trips through put_conversation/get_conversation" do
        conv = uid("conv")

        :ok = @adapter.put_conversation(conv, %{settings: %{}, feature: "interview"})
        assert @adapter.get_conversation(conv).feature == "interview"
      end

      test "tenant_key round-trips through put_conversation/get_conversation" do
        conv = uid("conv")
        tenant = uid("tenant")

        :ok = @adapter.put_conversation(conv, %{settings: %{"a" => 1}, tenant_key: tenant})
        assert @adapter.get_conversation(conv).tenant_key == tenant

        # A later write without :tenant_key leaves the stored key untouched.
        :ok = @adapter.put_conversation(conv, %{settings: %{"a" => 2}})
        assert @adapter.get_conversation(conv).tenant_key == tenant

        # A conversation written without a tenant reads back nil.
        untenanted = uid("conv")
        :ok = @adapter.put_conversation(untenanted, %{settings: %{}})
        assert @adapter.get_conversation(untenanted).tenant_key == nil
      end

      test "delete_by_tenant removes exactly the keyed conversations" do
        tenant = uid("tenant")
        [a, b, other] = [uid("conv"), uid("conv"), uid("conv")]

        for conv <- [a, b] do
          :ok = @adapter.put_conversation(conv, %{settings: %{}, tenant_key: tenant})
          {:ok, _seq} = @adapter.append_event(conv, Event.new(:user_msg, %{n: 1}))

          :ok =
            @adapter.upsert_tool_call(conv, %{
              id: uid("tc"),
              conversation_id: conv,
              name: "t",
              executor: :server,
              args: %{}
            })
        end

        :ok = @adapter.put_conversation(other, %{settings: %{}})
        {:ok, _seq} = @adapter.append_event(other, Event.new(:user_msg, %{n: 1}))

        assert @adapter.delete_by_tenant(tenant) == {:ok, 2}

        assert @adapter.get_conversation(a) == nil
        assert @adapter.get_conversation(b) == nil
        assert @adapter.stream_events(a) == []
        assert @adapter.pending_tool_calls(a) == []

        # The untenanted conversation is untouched; an unknown key deletes nothing.
        assert @adapter.get_conversation(other)
        assert length(@adapter.stream_events(other)) == 1
        assert @adapter.delete_by_tenant(uid("tenant")) == {:ok, 0}
      end
    end
  end
end
