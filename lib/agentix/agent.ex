defmodule Agentix.Agent do
  @moduledoc """
  The per-conversation agent — one `:gen_statem` process per conversation, addressed
  through `Agentix.Registry` and started under `Agentix.ConversationSupervisor`.

  ## States (turn loop)

      idle ─send_message─> preparing ─> streaming ─done(no tools)─> idle
                                          │
                                          └─done(tool_calls)─> executing_tools
      executing_tools ─all resolved─> preparing (next model call, same turn)
      executing_tools ─any suspends─> awaiting_input ─resolve─> preparing
      any non-idle ─cancel─> idle (records a partial assistant turn)

  A tool loop is several model calls **under one turn** — `executing_tools`/
  `awaiting_input` loop back into `preparing` (same `turn_ref`, new assistant
  message); only a tool-free completion ends the turn. Callback mode is
  `:state_functions`.

  ## Non-blocking principle

  The process never blocks on I/O. The LLM stream runs in a **monitored task**
  (under `Agentix.TaskSupervisor`); chunks arrive as `{:chunk, …}` messages,
  completion as `{:stream_done, …}`, failure surfaces via the task's `DOWN`. Inside
  the agent only bookkeeping happens (append to the log, broadcast a live event,
  pick the next transition), so `cancel`/`inspect` are always serviceable.

  ## Durability

  The append-only event log (`Agentix.Persistence`) is the source of truth; the
  agent rebuilds its working context from the log every turn and re-reads the max
  `seq` on revival. On `ensure_started`, `revive/2` reconciles the kill boundary:

    * a conversation suspended on a HITL tool comes back in `:awaiting_input` with its
      `calls` map rebuilt from the durable records, re-arming the timeout, so a post-kill
      `Agentix.resolve/4` is accepted (not `{:error, :stale}`);
    * a dangling `:tool_call` (no paired `:tool_result` — an auto-server tool killed
      mid-run, or one a durable expiry resolved while dead) is paired with the durable
      result if any, else an interrupted error (the tool is **not** re-executed);
    * a log ending in a dangling `:user_msg` (killed before any dispatch) is **re-run**.

  Suspension timeouts are armed twice — an in-process timer (drives the live agent) and a
  durable adapter-backed one (`schedule_expiry/3`, survives a kill); whichever fires first
  records the result, the other is a stale no-op.
  """

  @behaviour :gen_statem

  alias Agentix.Codec
  alias Agentix.Compaction
  alias Agentix.Conversation.Config
  alias Agentix.Event
  alias Agentix.Events.Publisher
  alias Agentix.Hook
  alias Agentix.Hook.OverflowError
  alias Agentix.Hook.Pipeline
  alias Agentix.Persistence
  alias Agentix.Provider
  alias Agentix.Scope
  alias Agentix.Tool
  alias Agentix.Tool.Dispatch
  alias Agentix.Turn
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  require Logger

  defmodule Data do
    @moduledoc false
    # FSM data. `turn` is `nil` outside a turn, else a map carrying the turn ref,
    # assistant msg_id, scope, the streaming task (task_pid/monitor_ref/cancel),
    # accumulated text/thinking, and `calls` (tool_call_id => call tracking entry).
    @enforce_keys [:conversation_id, :config, :publisher]
    defstruct [
      :conversation_id,
      :config,
      :publisher,
      last_seq: 0,
      model_call_seq: 0,
      turn: nil
    ]
  end

  ## Public addressing

  @doc "The Registry `via` tuple for a conversation (the single addressing point)."
  @spec via(String.t()) :: {:via, Registry, {Agentix.Registry, String.t()}}
  def via(conversation_id), do: {:via, Registry, {Agentix.Registry, conversation_id}}

  @typedoc "A point-in-time view of a conversation for a (re)connecting consumer."
  @type snapshot :: %{
          state: atom(),
          messages: [Message.t()],
          history_cursor: non_neg_integer() | nil,
          more?: boolean(),
          streaming_message:
            %{id: String.t(), text: String.t(), thinking: String.t(), seq: non_neg_integer()}
            | nil,
          in_flight_tools: %{optional(String.t()) => map()},
          pending: %{optional(String.t()) => map()}
        }

  @typedoc "A window of finalized messages plus a backward-pagination cursor."
  @type history_page :: %{
          messages: [Message.t()],
          cursor: non_neg_integer() | nil,
          more?: boolean()
        }

  @doc """
  A read-only snapshot for a (re)connecting UI: a window of the finalized message
  history plus the live turn state (current state, the in-progress assistant message's
  streamed text, and the in-flight/pending tool calls).

  `opts` are the windowing options of `history/2` (`:limit`, `:before`); the snapshot
  carries `:history_cursor` (oldest message's `seq`) and `:more?` so the consumer can
  page older. Safe whether or not the agent is running — an absent agent reports an idle
  turn and the history is read straight from the durable log. The live read never blocks
  the turn loop (it only inspects in-memory turn state).
  """
  @spec snapshot(String.t(), keyword()) :: snapshot()
  def snapshot(conversation_id, opts \\ []) when is_binary(conversation_id) do
    page = history(conversation_id, opts)

    conversation_id
    |> live_turn()
    |> Map.put(:messages, page.messages)
    |> Map.put(:history_cursor, page.cursor)
    |> Map.put(:more?, page.more?)
  end

  @doc """
  A window of the finalized conversation rendered as `ReqLLM.Message`s, oldest first.
  Options: `:limit` (most-recent N) and `:before` (exclusive `seq` upper bound) for
  backward pagination — see `Agentix.Persistence`. Returns the messages plus `:cursor`
  (the oldest loaded event's `seq`, `nil` when empty) and `:more?` (older events exist).
  With no options it returns the whole conversation.
  """
  @spec history(String.t(), keyword()) :: history_page()
  def history(conversation_id, opts \\ []) when is_binary(conversation_id) do
    events = Persistence.stream_events(conversation_id, Keyword.take(opts, [:limit, :before]))
    cursor = events |> Enum.map(& &1.seq) |> Enum.min(fn -> nil end)

    %{
      messages: Enum.flat_map(events, &event_to_messages/1),
      cursor: cursor,
      more?: cursor != nil and cursor > 1
    }
  end

  defp live_turn(conversation_id) do
    case Registry.lookup(Agentix.Registry, conversation_id) do
      [{_pid, _}] -> :gen_statem.call(via(conversation_id), :snapshot)
      [] -> idle_turn()
    end
  catch
    # The agent may exit between the lookup and the call (crash, revival churn, a
    # mid-stream kill). Treat that as 'no live turn' and fall back to the durable log
    # rather than crashing the caller (e.g. a mounting LiveView).
    :exit, _reason -> idle_turn()
  end

  defp idle_turn, do: %{state: :idle, streaming_message: nil, in_flight_tools: %{}, pending: %{}}

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :conversation_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Starts an agent for `conversation_id`. Pass `:config` (an `Agentix.Conversation.Config`)
  for a new conversation; on revival the config is rebuilt from the persisted
  settings, so `:config` may be omitted.
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    :gen_statem.start_link(via(conversation_id), __MODULE__, opts, [])
  end

  ## :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    case resolve_config(conversation_id, opts) do
      {:ok, config} ->
        Persistence.put_conversation(conversation_id, %{settings: Map.from_struct(config)})
        {summary, events} = Persistence.load_since(conversation_id)
        last_seq = max_seq(summary, events)

        data = %Data{
          conversation_id: conversation_id,
          config: config,
          publisher: Publisher.new(config, conversation_id),
          last_seq: last_seq,
          model_call_seq: last_model_call_seq(conversation_id, config)
        }

        {state, data, actions} = revive(data, events)
        {:ok, state, data, actions}

      :error ->
        {:stop, :unknown_conversation}
    end
  end

  ## State: idle

  def idle({:call, from}, {:send_message, message, scope}, data) do
    start_turn(message, scope, data, from)
  end

  def idle({:call, from}, :cancel, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # Recovery rerun: the user message is already in the log (only the LLM dispatch
  # was lost), so we re-launch the turn without re-appending it.
  def idle(:internal, {:rerun, scope}, data) do
    launch_turn(scope, data, nil)
  end

  def idle(event_type, event, data), do: handle_common(:idle, event_type, event, data)

  ## State: preparing — assemble context and launch the streaming task

  def preparing(:internal, :assemble, data) do
    base = assemble_context(data)

    # Pre-hooks run inline here (like context assembly itself); they inject context
    # and may halt the turn before any model call. Injections land at the context tail.
    case run_pre_hooks(data, base) do
      {:cont, %Turn{} = turn} ->
        launch_stream(data, apply_injections(turn.context, turn.injections))

      {:halt, reason} ->
        halt_turn(data, reason)
    end
  end

  def preparing({:call, from}, {:send_message, _m, _s}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def preparing({:call, from}, :cancel, data) do
    {data, actions} = abort_turn(data, from)
    {:next_state, :idle, data, actions}
  end

  def preparing(event_type, event, data), do: handle_common(:preparing, event_type, event, data)

  ## State: streaming — forward deltas, finalize on completion

  def streaming(:info, {:stream_started, ref, cancel}, %Data{turn: %{ref: ref}} = data) do
    {:keep_state, put_in(data.turn.cancel, cancel)}
  end

  def streaming(:info, {:chunk, ref, chunk}, %Data{turn: %{ref: ref}} = data) do
    {:keep_state, handle_chunk(chunk, data)}
  end

  def streaming(:info, {:stream_done, ref, message, usage}, %Data{turn: %{ref: ref}} = data) do
    complete_turn(message, usage, data)
  end

  def streaming(:info, {:stream_error, ref, reason}, %Data{turn: %{ref: ref}} = data) do
    fail_turn(reason, data)
  end

  def streaming(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        %Data{turn: %{monitor_ref: ref}} = data
      ) do
    case reason do
      :normal -> :keep_state_and_data
      _ -> fail_turn(reason, data)
    end
  end

  def streaming({:call, from}, {:send_message, _m, _s}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def streaming({:call, from}, :cancel, data) do
    {data, actions} = abort_turn(data, from)
    {:next_state, :idle, data, actions}
  end

  def streaming(event_type, event, data), do: handle_common(:streaming, event_type, event, data)

  ## State: executing_tools — server/provider calls in flight, none awaiting external

  def executing_tools(:info, {:tool_done, ref, id, result}, %Data{turn: %{ref: ref}} = data) do
    data |> do_record_result(id, result) |> advance(:executing_tools)
  end

  def executing_tools(:info, {:tool_timeout, ref, id}, %Data{turn: %{ref: ref}} = data) do
    maybe_timeout(data, id, :executing_tools)
  end

  def executing_tools(:info, {:DOWN, mref, :process, _pid, reason}, %Data{} = data) do
    tool_task_down(data, mref, reason, :executing_tools)
  end

  def executing_tools({:call, from}, {:resolve, id, result, scope}, data) do
    handle_resolve(data, from, id, result, scope, :executing_tools)
  end

  def executing_tools({:call, from}, {:send_message, _m, _s}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def executing_tools({:call, from}, :cancel, data) do
    {data, actions} = abort_turn(data, from)
    {:next_state, :idle, data, actions}
  end

  def executing_tools(event_type, event, data),
    do: handle_common(:executing_tools, event_type, event, data)

  ## State: awaiting_input — at least one call awaiting an external resolution

  def awaiting_input({:call, from}, {:resolve, id, result, scope}, data) do
    handle_resolve(data, from, id, result, scope, :awaiting_input)
  end

  def awaiting_input(:info, {:tool_done, ref, id, result}, %Data{turn: %{ref: ref}} = data) do
    data |> do_record_result(id, result) |> advance(:awaiting_input)
  end

  def awaiting_input(:info, {:tool_timeout, ref, id}, %Data{turn: %{ref: ref}} = data) do
    maybe_timeout(data, id, :awaiting_input)
  end

  def awaiting_input(:info, {:DOWN, mref, :process, _pid, reason}, %Data{} = data) do
    tool_task_down(data, mref, reason, :awaiting_input)
  end

  def awaiting_input({:call, from}, {:send_message, _m, _s}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def awaiting_input({:call, from}, :cancel, data) do
    {data, actions} = abort_turn(data, from)
    {:next_state, :idle, data, actions}
  end

  def awaiting_input(event_type, event, data),
    do: handle_common(:awaiting_input, event_type, event, data)

  ## Shared handlers

  # Stale stream messages from a superseded/cancelled turn (ref no longer current)
  # are dropped. `:stream_done` is the only 4-tuple; the rest are 3-tuples.
  defp handle_common(_state, :info, {:stream_done, _ref, _msg, _usage}, _data) do
    :keep_state_and_data
  end

  defp handle_common(_state, :info, {tag, _ref, _a}, _data)
       when tag in [:stream_started, :chunk, :stream_error] do
    :keep_state_and_data
  end

  defp handle_common(_state, :info, {:DOWN, _ref, :process, _pid, _reason}, _data) do
    :keep_state_and_data
  end

  # A resolve for a conversation that is not awaiting this id (no turn, wrong state,
  # or already resolved) is stale, not a crash.
  defp handle_common(_state, {:call, from}, {:resolve, _id, _result, _scope}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :stale}}]}
  end

  # Read-only live turn view for `snapshot/1`, served from any state.
  defp handle_common(state, {:call, from}, :snapshot, data) do
    {:keep_state_and_data, [{:reply, from, live_turn_view(state, data)}]}
  end

  # Late tool-task signals from a finished/superseded turn.
  defp handle_common(_state, :info, {:tool_done, _ref, _id, _result}, _data),
    do: :keep_state_and_data

  defp handle_common(_state, :info, {:tool_timeout, _ref, _id}, _data), do: :keep_state_and_data

  defp handle_common(_state, _event_type, _event, _data), do: :keep_state_and_data

  ## Turn lifecycle

  # A fresh user message: append it to the log, then launch the turn. The turn
  # assembles its context by reading the log, so the message is not threaded further.
  defp start_turn(message, scope, data, from) do
    {:ok, seq} = append_event(data, :user_msg, message_content(normalize_user_message(message)))
    launch_turn(scope, %{data | last_seq: seq}, from)
  end

  defp launch_turn(scope, data, from) do
    data = %{data | turn: base_turn(scope)}
    Publisher.turn_started(data.publisher, data.turn.ref)
    Publisher.state_changed(data.publisher, :preparing)

    reply = if from, do: [{:reply, from, :ok}], else: []
    {:next_state, :preparing, data, reply ++ [{:next_event, :internal, :assemble}]}
  end

  # A fresh turn's in-memory state. `ref` keys this turn's tool tasks/events; `calls` and
  # `task_index` track in-flight tool calls. (`continue_turn/1` keeps the same `ref` for a
  # tool loop; `revive_awaiting/2` rebuilds this with a restored `calls` map.)
  defp base_turn(scope) do
    %{
      ref: make_ref(),
      msg_id: new_msg_id(),
      scope: scope,
      task_pid: nil,
      monitor_ref: nil,
      cancel: nil,
      context: nil,
      text: "",
      thinking: "",
      # Monotonic per-message delta counter; lets a reconnect snapshot dedupe replayed
      # text/thinking deltas (reset whenever a new assistant message begins).
      delta_seq: 0,
      # tool_call_id => %{tool, name, args, phase, task, result, timer}
      calls: %{},
      # monitor_ref => tool_call_id, for O(1) crashed-task lookup on :DOWN
      task_index: %{}
    }
  end

  # Spawn the monitored streaming task over the (post-injection) context and move to
  # streaming. Split from `preparing` so the pre-hook pipeline sits cleanly before it.
  defp launch_stream(data, context) do
    turn = data.turn
    agent = self()
    model = data.config.model
    # Tools are handed to the provider for schema/serialization; the loop dispatches
    # them itself (the provider never auto-executes). Other opts (temperature,
    # max_tokens, pool config) are derived from config in a later increment.
    opts = stream_opts(data.config)
    transformer = data.config.stream_transformer

    %{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(Agentix.TaskSupervisor, fn ->
        run_stream(agent, turn.ref, model, context, opts, transformer)
      end)

    :telemetry.execute(
      [:agentix, :turn, :start],
      %{system_time: System.system_time()},
      %{conversation_id: data.conversation_id, turn_ref: turn.ref}
    )

    data = put_in(data.turn, %{turn | task_pid: pid, monitor_ref: ref, context: context})
    Publisher.state_changed(data.publisher, :streaming)
    {:next_state, :streaming, data}
  end

  # A hook halted the turn — pre-hook (no model call happened, no assistant message)
  # or post-hook (the message already finalized, but the turn stops here). Either way
  # `{:turn_halted, ...}` is the terminal live event (the counterpart to
  # `turn_completed`/`cancelled`), so every `turn_started` has exactly one terminal.
  defp halt_turn(data, reason) do
    Logger.info("agentix turn halted: #{inspect(reason)}")
    Publisher.turn_halted(data.publisher, data.turn.ref, reason)

    :telemetry.execute(
      [:agentix, :turn, :halt],
      %{},
      %{conversation_id: data.conversation_id, turn_ref: data.turn.ref, reason: reason}
    )

    finish(data, :idle)
  end

  defp complete_turn(message, usage, data) do
    turn = data.turn
    drop_monitor(turn)
    message = put_msg_id(message, turn.msg_id)
    {:ok, seq} = append_event(data, :assistant_msg, message_content(message))
    data = maybe_audit(%{data | last_seq: seq}, message, usage)

    Publisher.message_completed(data.publisher, turn.ref, message)

    # Post-hooks run after the message finalizes. A :halt ends the turn (no further
    # model calls); otherwise the tool-loop branch decides whether the turn continues.
    case run_post_hooks(data, message) do
      {:halt, reason} ->
        halt_turn(data, reason)

      {:cont, _turn} ->
        case message.tool_calls do
          [_ | _] = tool_calls -> begin_tool_calls(data, tool_calls)
          _ -> finish_turn(data)
        end
    end
  end

  # No tool calls — the turn is genuinely complete.
  defp finish_turn(data) do
    Publisher.turn_completed(data.publisher, data.turn.ref)

    :telemetry.execute(
      [:agentix, :turn, :stop],
      %{},
      %{conversation_id: data.conversation_id, turn_ref: data.turn.ref}
    )

    maybe_summarize(data)
    finish(data, :idle)
  end

  # Between turns: if the free reducers left the rendered context over budget, kick off
  # prefix-ward summarization off the critical path — it writes a `summaries` row the
  # next assembly reads. Best-effort; failure just means the next over-budget turn
  # retries. Never on the turn's hot path (it ran in `streaming`, this is at the end).
  defp maybe_summarize(%Data{turn: %{context: %Context{} = context}} = data) do
    if Compaction.over_budget?(context, compaction_budget(data.config)) do
      Compaction.Summarize.start(data.conversation_id, data.config)
    end

    :ok
  end

  defp maybe_summarize(_data), do: :ok

  # The stream failed (provider error or task crash). Record the partial text we did
  # receive (if any) so the log keeps a faithful assistant turn, then return to idle.
  defp fail_turn(reason, data) do
    turn = data.turn
    drop_monitor(turn)
    Logger.warning("agentix stream failed: #{inspect(reason)}")

    data = record_partial(data, :error)
    Publisher.cancelled(data.publisher, turn.ref)

    :telemetry.execute(
      [:agentix, :turn, :exception],
      %{},
      %{conversation_id: data.conversation_id, turn_ref: turn.ref, reason: reason}
    )

    finish(data, :idle)
  end

  # Cancel from any non-idle state: stop the streaming task, invoke the provider's
  # cancel closure so the socket actually closes, record the partial assistant turn.
  defp abort_turn(data, from) do
    turn = data.turn

    drop_monitor(turn)
    if turn.task_pid, do: Task.Supervisor.terminate_child(Agentix.TaskSupervisor, turn.task_pid)
    if is_function(turn.cancel, 0), do: turn.cancel.()

    data = cancel_tool_calls(data)
    data = record_partial(data, :cancelled)
    Publisher.cancelled(data.publisher, turn.ref)

    :telemetry.execute(
      [:agentix, :turn, :exception],
      %{},
      %{conversation_id: data.conversation_id, turn_ref: turn.ref, reason: :cancelled}
    )

    Persistence.put_fsm_state(data.conversation_id, fsm_state(:idle, data.last_seq))
    Publisher.state_changed(data.publisher, :idle)
    {%{data | turn: nil}, [{:reply, from, :ok}]}
  end

  # Persist whatever assistant text streamed so far as a (partial) assistant_msg, so
  # every turn leaves a paired record. `status` (`:cancelled`/`:error`) is recorded in the
  # message metadata, not baked into the text, so the UI can render clean text plus its own
  # badge; the model-context path re-applies a marker (see `mark_truncated/1`). The partial
  # is broadcast as a completed message (same as a normal finish) so a connected client
  # keeps the streamed text instead of having it vanish when the turn resets.
  defp record_partial(data, status) do
    turn = data.turn

    message =
      put_msg_id(
        %Message{
          role: :assistant,
          content: [ContentPart.text(turn.text)],
          metadata: %{"status" => to_string(status)}
        },
        turn.msg_id
      )

    {:ok, seq} = append_event(data, :assistant_msg, message_content(message))
    Publisher.message_completed(data.publisher, turn.ref, message)
    %{data | last_seq: seq}
  end

  defp finish(data, state) do
    Persistence.put_fsm_state(data.conversation_id, fsm_state(state, data.last_seq))
    Publisher.state_changed(data.publisher, state)
    {:next_state, state, %{data | turn: nil}}
  end

  # Release the streaming task's monitor and flush any pending `:DOWN` so it does not
  # linger in the mailbox after the turn ends.
  defp drop_monitor(%{monitor_ref: ref}) when is_reference(ref),
    do: Process.demonitor(ref, [:flush])

  defp drop_monitor(_turn), do: :ok

  ## Tool execution

  # The assistant message carried tool calls. Record each as a `:tool_call` event,
  # start it per its executor, then pick the next state.
  defp begin_tool_calls(data, tool_calls) do
    data = Enum.reduce(tool_calls, data, fn tool_call, acc -> begin_one_call(acc, tool_call) end)
    # Entered from `streaming` (the assistant message just finalized), so any target
    # state is a genuine transition.
    advance(data, :streaming)
  end

  defp begin_one_call(data, %ReqLLM.ToolCall{id: id, function: function}) do
    name = function["name"] || function[:name]

    case parse_args(function["arguments"] || function[:arguments]) do
      {:ok, args} ->
        {:ok, seq} =
          append_event(data, :tool_call, %{"tool_call_id" => id, "name" => name, "args" => args})

        tool = find_tool(data.config, name)
        start_call(%{data | last_seq: seq}, id, name, tool, args)

      :error ->
        # The model emitted unparseable arguments. Don't crash the agent — record an
        # error result so the call/result pair stays intact and the model can retry.
        {:ok, seq} =
          append_event(data, :tool_call, %{"tool_call_id" => id, "name" => name, "args" => %{}})

        %{data | last_seq: seq}
        |> update_call(id, call_entry(nil, name, %{}, :done))
        |> do_record_result(id, %{ok: false, error: "invalid tool arguments"})
    end
  end

  # Unknown tool the model hallucinated — record an error result so the call/result
  # pair stays intact (providers reject orphan tool_calls).
  defp start_call(data, id, name, nil, args) do
    data
    |> update_call(id, call_entry(nil, name, args, :done))
    |> do_record_result(id, %{ok: false, error: "unknown tool: #{name}"})
  end

  # Provider-hosted: resolves in-stream. Records a pass-through result and never
  # dispatches it locally (a full provider-tool round-trip is not yet implemented).
  defp start_call(data, id, name, %Tool{executor: :provider} = tool, args) do
    data
    |> update_call(id, call_entry(tool, name, args, :done))
    |> do_record_result(id, %{ok: true, result: nil})
  end

  # Server, auto: dispatch the callback in a monitored task; it reports back via
  # `{:tool_done, ...}`. A running server call is internal — not a persisted pending.
  defp start_call(data, id, name, %Tool{executor: :server, approval: :auto} = tool, args) do
    Publisher.tool_call_started(data.publisher, id, name, :server, args)

    task =
      Dispatch.run_server(self(), data.turn.ref, id, tool, args, build_turn(data, data.turn.scope))

    data
    |> track_task(task.ref, id)
    |> update_call(id, call_entry(tool, name, args, :running, task: task))
  end

  # Everything else suspends and awaits an external resolution: gated `:server` /
  # `:client` (approval first), `:human` (elicitation), `:client` (client exec).
  defp start_call(data, id, name, %Tool{} = tool, args) do
    phase = suspend_phase(tool)
    suspend_call(data, id, name, tool, args, phase)
  end

  defp suspend_call(data, id, name, %Tool{} = tool, args, phase) do
    kind = phase_kind(tool, phase)

    Persistence.upsert_tool_call(data.conversation_id, %{
      id: id,
      conversation_id: data.conversation_id,
      name: name,
      executor: tool.executor,
      status: :pending,
      args: args
    })

    Publisher.tool_call_started(data.publisher, id, name, tool.executor, args)
    Publisher.suspended(data.publisher, id, tool.executor, %{kind: kind, args: args})
    # Two timers: the in-process one drives this live agent; the durable one (adapter-owned)
    # is the backstop that fires even if the agent is killed (see `do_record_result/3` and
    # `revive_awaiting/2`). Both are cancelled on any terminal outcome.
    timer = arm_timeout(data, id)
    Persistence.schedule_expiry(data.conversation_id, id, data.config.default_timeout)
    update_call(data, id, call_entry(tool, name, args, phase, timer: timer))
  end

  # Resolution arrived for a pending call. Reply `:ok` immediately, then advance.
  # `scope` is the resolver's (e.g. the approver), threaded into a post-approval
  # `:server` dispatch so the callback runs as whoever authorized it.
  defp handle_resolve(data, from, id, result, scope, from_state) do
    case current_call(data, id) do
      %{phase: phase} = call when phase in [:awaiting_approval, :awaiting_exec, :awaiting_human] ->
        data
        |> apply_resolution(id, call, result, scope)
        |> advance(from_state)
        |> with_reply(from, :ok)

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :stale}}]}
    end
  end

  # Gated call: approve transitions to the executor's real phase; deny resolves it.
  defp apply_resolution(data, id, %{phase: :awaiting_approval, tool: tool}, result, scope) do
    if approved?(result) do
      approve_call(data, id, tool, scope)
    else
      do_record_result(data, id, %{ok: false, error: "denied by approver"})
    end
  end

  # Client exec output or human elicitation answer — the resolution value is the result.
  defp apply_resolution(data, id, _call, result, _scope) do
    do_record_result(data, id, Dispatch.normalize_result(result))
  end

  defp approve_call(data, id, %Tool{executor: :server} = tool, scope) do
    # No longer awaiting external input; clear the durable pending record, then run
    # the callback as the approver.
    call = current_call(data, id)
    cancel_timer(call.timer)
    Persistence.cancel_expiry(data.conversation_id, id)
    Persistence.resolve_tool_call(id, :resolved, %{approved: true})
    Publisher.tool_call_started(data.publisher, id, call.name, :server, call.args)
    task = Dispatch.run_server(self(), data.turn.ref, id, tool, call.args, build_turn(data, scope))

    data
    |> track_task(task.ref, id)
    |> update_call(id, %{call | phase: :running, task: task, timer: nil})
  end

  defp approve_call(data, id, %Tool{executor: :client}, _scope) do
    # Gated client: second suspension for the actual client execution. Re-arm both timers
    # from this moment — including the durable expiry (cancel + reschedule) — so the
    # backstop tracks the second phase's deadline instead of firing early off the first
    # suspension's clock.
    call = current_call(data, id)
    cancel_timer(call.timer)
    Persistence.cancel_expiry(data.conversation_id, id)
    Publisher.suspended(data.publisher, id, :client, %{kind: :client_exec, args: call.args})
    timer = arm_timeout(data, id)
    Persistence.schedule_expiry(data.conversation_id, id, data.config.default_timeout)
    update_call(data, id, %{call | phase: :awaiting_exec, timer: timer})
  end

  # Records a terminal result for a call: writes the paired `:tool_result` event,
  # clears any durable pending record, broadcasts, and marks the call done.
  defp do_record_result(data, id, result) do
    call = current_call(data, id)
    cancel_timer(call.timer)
    # A `timer` means this call was suspended, so it also has a durable expiry to cancel.
    if call.timer, do: Persistence.cancel_expiry(data.conversation_id, id)
    # Release the server task's monitor (flushing its now-irrelevant normal `:DOWN`)
    # so it never reaches `tool_task_down`, and drop it from the crash index.
    data = release_task(data, call)

    {:ok, seq} =
      append_event(data, :tool_result, %{
        "tool_call_id" => id,
        "name" => call.name,
        "result" => result
      })

    Persistence.resolve_tool_call(id, result_status(result), result)
    broadcast_result(data.publisher, id, result)
    update_call(%{data | last_seq: seq}, id, %{call | phase: :done, result: result, timer: nil})
  end

  defp maybe_timeout(data, id, from_state) do
    case current_call(data, id) do
      %{phase: phase} when phase in [:awaiting_approval, :awaiting_exec, :awaiting_human] ->
        data
        |> do_record_result(id, %{ok: false, error: "timed out: no response"})
        |> advance(from_state)

      _ ->
        :keep_state_and_data
    end
  end

  # A server tool task crashed before reporting. The crashed call's id is resolved in
  # O(1) via the turn's `monitor_ref => id` index. A `:normal` exit never reaches here
  # — `do_record_result` demonitors+flushes the task on `:tool_done`.
  defp tool_task_down(data, mref, reason, from_state) do
    case data.turn.task_index[mref] do
      nil ->
        :keep_state_and_data

      id ->
        data
        |> do_record_result(id, %{ok: false, error: "tool crashed: #{inspect(reason)}"})
        |> advance(from_state)
    end
  end

  # Pick the next state from the calls' phases. `from_state` lets us skip a no-op
  # `:state_changed` broadcast when the FSM stays put (e.g. one of several pending
  # calls resolves but others still await).
  defp advance(data, from_state) do
    calls = data.turn.calls

    cond do
      Enum.all?(calls, fn {_id, c} -> c.phase == :done end) -> continue_turn(data)
      Enum.any?(calls, fn {_id, c} -> awaiting?(c.phase) end) -> enter_awaiting(data, from_state)
      true -> enter_executing(data, from_state)
    end
  end

  # All tool results are in — feed them back to the model in a new model call under
  # the *same* turn (a tool loop is several model calls per turn, not a new turn).
  defp continue_turn(data) do
    # A blank turn that keeps the loop's `ref` (so this turn's tool tasks/events stay keyed
    # to it) but gets a fresh `msg_id` and zeroed accumulators. Derived from `base_turn/1`
    # so any new turn field stays in sync automatically.
    turn = %{base_turn(data.turn.scope) | ref: data.turn.ref}

    Publisher.state_changed(data.publisher, :preparing)
    {:next_state, :preparing, %{data | turn: turn}, [{:next_event, :internal, :assemble}]}
  end

  # The persisted pending set may have changed even when staying in `:awaiting_input`,
  # so always re-persist it; only broadcast `:state_changed` on a real transition.
  defp enter_awaiting(data, from_state) do
    Persistence.put_fsm_state(data.conversation_id, %{
      state: :awaiting_input,
      pending: pending_subset(data.turn.calls),
      last_seq: data.last_seq
    })

    if from_state != :awaiting_input, do: Publisher.state_changed(data.publisher, :awaiting_input)
    {:next_state, :awaiting_input, data}
  end

  defp enter_executing(data, from_state) do
    if from_state != :executing_tools, do: Publisher.state_changed(data.publisher, :executing_tools)
    {:next_state, :executing_tools, data}
  end

  ## Tool helpers

  defp call_entry(tool, name, args, phase, opts \\ []) do
    %{
      tool: tool,
      name: name,
      args: args,
      phase: phase,
      task: Keyword.get(opts, :task),
      result: nil,
      timer: Keyword.get(opts, :timer)
    }
  end

  defp update_call(data, id, entry) do
    %{data | turn: %{data.turn | calls: Map.put(data.turn.calls, id, entry)}}
  end

  defp current_call(%Data{turn: %{calls: calls}}, id), do: Map.get(calls, id)
  defp current_call(_data, _id), do: nil

  defp track_task(data, ref, id) do
    %{data | turn: %{data.turn | task_index: Map.put(data.turn.task_index, ref, id)}}
  end

  # Demonitor (flushing any pending `:DOWN`) and drop a finished/cancelled server
  # task from the crash index. A no-op for non-server calls (no task).
  defp release_task(data, %{task: %Task{ref: ref}}) do
    Process.demonitor(ref, [:flush])
    %{data | turn: %{data.turn | task_index: Map.delete(data.turn.task_index, ref)}}
  end

  defp release_task(data, _call), do: data

  defp awaiting?(phase), do: phase in [:awaiting_approval, :awaiting_exec, :awaiting_human]

  defp suspend_phase(%Tool{approval: :requires_approval}), do: :awaiting_approval
  defp suspend_phase(%Tool{executor: :human}), do: :awaiting_human
  defp suspend_phase(%Tool{executor: :client}), do: :awaiting_exec

  defp phase_kind(tool, :awaiting_approval), do: Tool.pending_kind(tool, :approval)
  defp phase_kind(tool, _phase), do: Tool.pending_kind(tool, :exec)

  # The renderer/persisted pending: only the awaiting-external subset.
  # `tool` is nil only for a revived call whose tool is no longer in the config; skip it
  # from the cache (the durable `pending_tool_calls` row remains authoritative for it).
  defp pending_subset(calls) do
    for {id, %{phase: phase, tool: tool} = call} <- calls,
        awaiting?(phase),
        tool != nil,
        into: %{} do
      {id,
       %{
         name: call.name,
         executor: tool.executor,
         kind: phase_kind(tool, phase),
         prompt: call.args
       }}
    end
  end

  # The in-memory turn projected for `snapshot/1`. The streamed text is reported only
  # while an assistant message is being produced (`preparing`/`streaming`); once a turn
  # is executing or awaiting tools its assistant message is already finalized in the log.
  defp live_turn_view(state, %Data{turn: turn}) do
    %{
      state: state,
      streaming_message: streaming_view(state, turn),
      in_flight_tools: in_flight_view(turn),
      pending: pending_view(turn)
    }
  end

  defp streaming_view(state, %{} = turn) when state in [:preparing, :streaming],
    do: %{id: turn.msg_id, text: turn.text, thinking: turn.thinking, seq: turn.delta_seq}

  defp streaming_view(_state, _turn), do: nil

  # Server tool calls dispatched and still running (suspended calls are `pending`).
  defp in_flight_view(%{calls: calls}) do
    for {id, %{phase: :running, tool: tool} = call} <- calls, tool != nil, into: %{} do
      {id, %{name: call.name, executor: tool.executor, status: :running}}
    end
  end

  defp in_flight_view(_turn), do: %{}

  defp pending_view(%{calls: calls}), do: pending_subset(calls)
  defp pending_view(_turn), do: %{}

  defp build_turn(data, scope) do
    Turn.new(context: data.turn.context, turn_ref: data.turn.ref, scope: scope)
  end

  defp find_tool(%Config{tools: tools}, name), do: Enum.find(tools, &(&1.name == name))

  # Returns `{:ok, map}` or `:error` — model-supplied arguments must never crash the
  # agent (this runs in the agent process, after the stream already finished).
  defp parse_args(args) when is_map(args), do: {:ok, args}

  defp parse_args(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp parse_args(_other), do: {:ok, %{}}

  defp approved?(:approve), do: true
  defp approved?(%{approved: value}), do: value == true
  defp approved?(%{"approved" => value}), do: value == true
  defp approved?(_other), do: false

  defp result_status(%{ok: true}), do: :resolved
  defp result_status(_result), do: :errored

  defp broadcast_result(publisher, id, %{ok: true} = result),
    do: Publisher.tool_call_resolved(publisher, id, result)

  defp broadcast_result(publisher, id, result),
    do: Publisher.tool_call_errored(publisher, id, result)

  defp arm_timeout(data, id),
    do: Process.send_after(self(), {:tool_timeout, data.turn.ref, id}, data.config.default_timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp with_reply({:next_state, state, data, actions}, from, reply),
    do: {:next_state, state, data, [{:reply, from, reply} | actions]}

  defp with_reply({:next_state, state, data}, from, reply),
    do: {:next_state, state, data, [{:reply, from, reply}]}

  # On cancel, shut down running server tasks, cancel timers, and synthesize a
  # `[cancelled]` result for every unresolved call so each tool_call keeps a pair.
  defp cancel_tool_calls(%Data{turn: %{calls: calls}} = data) do
    Enum.reduce(calls, data, fn
      {_id, %{phase: :done}}, acc ->
        acc

      {id, call}, acc ->
        cancel_timer(call.timer)
        terminate_task(call.task)
        # `do_record_result` releases the monitor (demonitor + flush) and untracks it.
        do_record_result(acc, id, %{ok: false, error: "[cancelled]"})
    end)
  end

  defp cancel_tool_calls(data), do: data

  defp terminate_task(%Task{pid: pid}),
    do: Task.Supervisor.terminate_child(Agentix.TaskSupervisor, pid)

  defp terminate_task(_no_task), do: :ok

  ## Streaming task (runs under Agentix.TaskSupervisor)

  defp run_stream(agent, turn_ref, model, context, opts, transformer) do
    case Provider.stream(model, context, opts) do
      {:ok, stream} ->
        send(agent, {:stream_started, turn_ref, stream.cancel})

        # The stream-transformer seam: one `(chunk -> chunk)` pass per chunk
        # (identity when unset), applied here at the provider seam before forwarding.
        Enum.each(stream.chunks, fn chunk ->
          send(agent, {:chunk, turn_ref, Hook.transform_chunk(chunk, transformer)})
        end)

        {message, usage} = stream.finalize.()
        send(agent, {:stream_done, turn_ref, message, usage})

      {:error, reason} ->
        send(agent, {:stream_error, turn_ref, reason})
    end
  end

  defp handle_chunk(%{type: :content, text: text}, data) when is_binary(text) do
    turn = data.turn
    Publisher.text_delta(data.publisher, turn.ref, turn.msg_id, text, turn.delta_seq)
    %{data | turn: %{turn | text: turn.text <> text, delta_seq: turn.delta_seq + 1}}
  end

  defp handle_chunk(%{type: :thinking, text: text}, data) when is_binary(text) do
    turn = data.turn
    Publisher.thinking_delta(data.publisher, turn.ref, turn.msg_id, text, turn.delta_seq)
    %{data | turn: %{turn | thinking: turn.thinking <> text, delta_seq: turn.delta_seq + 1}}
  end

  # :tool_call chunks carry no id (harvested post-stream from the assistant message);
  # :meta is noise.
  defp handle_chunk(_chunk, data), do: data

  ## Hook pipeline

  # Run the pre-pipeline. The OverflowError is *raised* by the pipeline (the loud
  # signal); the FSM rescues it into a turn halt rather than crashing into a restart
  # loop. Only the exception *message* (not the struct) reaches the halt reason →
  # telemetry, to avoid leaking closure-captured data into metrics handlers.
  defp run_pre_hooks(data, base) do
    config = data.config
    turn = build_hook_turn(data, base)
    Pipeline.run_pre(turn, pre_hooks(config), config.injection_reserve, config.hook_timeout)
  rescue
    e in OverflowError ->
      Logger.error("agentix pre-hook injection overflow: " <> Exception.message(e))
      {:halt, {:injection_overflow, e.hook}}

    e ->
      Logger.error("agentix pre-hook crashed: " <> Exception.message(e))
      {:halt, {:hook_crashed, Exception.message(e)}}
  end

  # Post-hooks are side-effecting; a crash must not unwind an already-completed turn,
  # so a crash is logged and treated as `:cont`. `run_post` handles an empty list.
  defp run_post_hooks(data, message) do
    Pipeline.run_post(build_post_turn(data, message), post_hooks(data.config))
  rescue
    e ->
      Logger.error("agentix post-hook crashed: " <> Exception.message(e))
      {:cont, nil}
  end

  defp pre_hooks(%Config{hooks: hooks}), do: Enum.filter(hooks, &(&1.phase == :pre))
  defp post_hooks(%Config{hooks: hooks}), do: Enum.filter(hooks, &(&1.phase == :post))

  defp build_hook_turn(data, context) do
    Turn.new(
      context: context,
      user_message: last_user_message(context),
      turn_ref: data.turn.ref,
      scope: data.turn.scope
    )
  end

  defp build_post_turn(data, message) do
    Turn.new(
      context: data.turn.context,
      assistant_message: message,
      turn_ref: data.turn.ref,
      scope: data.turn.scope
    )
  end

  defp last_user_message(%Context{messages: messages}) do
    Enum.find(Enum.reverse(messages), &match?(%Message{role: :user}, &1))
  end

  # Place pre-hook injections at the context tail (past the cache breakpoint): append
  # them to the final user message's content when there is one (keeping the tail a
  # single user message), else as a trailing user message (e.g. a tool-loop step).
  defp apply_injections(context, []), do: context

  defp apply_injections(%Context{messages: messages} = context, injections) do
    %{context | messages: place_injections(messages, injections)}
  end

  defp place_injections(messages, injections) do
    case List.last(messages) do
      %Message{role: :user, content: content} = last ->
        List.replace_at(messages, -1, %{last | content: content ++ injections})

      _ ->
        messages ++ [%Message{role: :user, content: injections}]
    end
  end

  ## Context assembly + compaction

  # Read "latest summary + events after it" (load_since), render to messages, compact
  # to fit the budget, then mark the prompt-cache breakpoint at the stable-prefix
  # boundary. With no summary this is identical to streaming all events. The injection
  # reserve is carved out of the budget so pre-hook injections (added at the tail
  # afterward, past the breakpoint) stay within the window without busting the cache.
  defp assemble_context(data) do
    {summary, events} = Persistence.load_since(data.conversation_id)

    history =
      events
      |> Enum.flat_map(&event_to_messages/1)
      |> Enum.map(&mark_truncated/1)
      |> Enum.map(&strip_internal_metadata/1)

    (system_prefix(data.config) ++ summary_prefix(summary) ++ history)
    |> Context.new()
    |> Compaction.compact(compaction_budget(data.config), data.config)
    |> place_cache_breakpoint()
  end

  # Mark a prompt-cache breakpoint on the stable prefix: the last content part of the
  # last leading system message (the summary message when present, else the system
  # prompt). Everything up to that block is byte-stable across turns — it changes only
  # when a new summary is written — so providers serve it from cache; the verbatim tail
  # and tail-appended injections sit past the breakpoint. No leading system message
  # means there is no stable prefix worth caching, so the context is returned as-is.
  # The marker rides `ContentPart.metadata` (honored by providers that support prompt
  # caching, ignored by those that don't) and is added per-assembly — never persisted.
  defp place_cache_breakpoint(%Context{messages: messages} = context) do
    case Enum.split_while(messages, &system_message?/1) do
      {[], _rest} -> context
      {system, rest} -> %{context | messages: mark_last(system) ++ rest}
    end
  end

  defp system_message?(%Message{role: :system}), do: true
  defp system_message?(_message), do: false

  defp mark_last(messages), do: List.replace_at(messages, -1, mark_message(List.last(messages)))

  defp mark_message(%Message{content: []} = message), do: message

  defp mark_message(%Message{content: parts} = message),
    do: %{message | content: List.replace_at(parts, -1, mark_part(List.last(parts)))}

  defp mark_part(%ContentPart{metadata: metadata} = part),
    do: %{part | metadata: Map.put(metadata || %{}, :cache_control, %{type: "ephemeral"})}

  defp system_prefix(config) do
    case config.system_prompt do
      nil -> []
      "" -> []
      prompt -> [Context.system(prompt)]
    end
  end

  defp summary_prefix(nil), do: []

  defp summary_prefix(summary) do
    content = summary[:content] || summary["content"]
    [Codec.decode_message(content["message"] || content[:message])]
  end

  defp compaction_budget(config) do
    Compaction.Budget.new(max(0, config.working_budget - config.injection_reserve))
  end

  # Maps a log event to messages. `:tool_call` events carry no message of their own —
  # the calls already ride on the assistant message — so they are skipped; `:tool_result`
  # events become `:tool` messages decorated with `tool_name`/`tool_status` so the default
  # components can render a named card. That metadata (plus the assistant `id`/`status`
  # bookkeeping) is internal — the UI path keeps it; `assemble_context/1` strips it via
  # `strip_internal_metadata/1` before the model boundary.
  defp event_to_messages(%Event{type: type, content: content})
       when type in [:user_msg, :assistant_msg],
       do: [Codec.decode_message(content["message"] || content[:message])]

  defp event_to_messages(%Event{type: :tool_result, content: content}) do
    id = content["tool_call_id"] || content[:tool_call_id]
    name = content["name"] || content[:name]
    result = content["result"] || content[:result]

    [
      %Message{
        role: :tool,
        tool_call_id: id,
        content: [ContentPart.text(Codec.encode_tool_result(result))],
        metadata: %{"tool_name" => name, "tool_status" => to_string(tool_result_status(result))}
      }
    ]
  end

  defp event_to_messages(_event), do: []

  # Agentix stamps internal bookkeeping onto `Message.metadata` (a stream `id`, a turn
  # `status`, a tool's display `name`/`status`) — none of it for the model. The OpenAI-format
  # encoder serializes `Message.metadata` verbatim onto the wire, so the model boundary keeps
  # only an allowlist of provider-meaningful keys and drops everything else; an unknown key
  # (a new internal stamp, a provider response field) can never leak by default.
  #
  # The allowlist is empty today: nothing in Agentix puts a provider-meaningful key on
  # `Message.metadata`. Provider hints ride elsewhere — `:cache_control` on `ContentPart`
  # metadata (the only key ReqLLM's content encoder forwards) and provider data on
  # `Message.provider_data` — neither of which this touches.
  @wire_metadata_keys []

  defp strip_internal_metadata(%Message{metadata: metadata} = message) when is_map(metadata),
    do: %{message | metadata: Map.take(metadata, @wire_metadata_keys)}

  defp strip_internal_metadata(message), do: message

  # Model-context only: a partial assistant turn stores its `status` in metadata (clean
  # text for the UI). Re-append a short marker so the model still sees the turn was cut —
  # the UI path (`history/2`) skips this and renders the clean text plus its own badge.
  # Runs before `strip_internal_metadata/1`, while the `status` key is still present.
  defp mark_truncated(%Message{metadata: %{"status" => status}} = message)
       when status in ["cancelled", "error"] do
    %{message | content: message.content ++ [ContentPart.text(truncation_marker(status))]}
  end

  defp mark_truncated(message), do: message

  defp truncation_marker("cancelled"), do: " [turn cancelled]"
  defp truncation_marker("error"), do: " [turn interrupted]"

  # UI status for a finalized tool result. Mirrors `result_status/1` but collapses to the
  # `:ok | :error` the `tool/1` component expects, and tolerates string keys (the Ecto
  # adapter JSON-encodes results; the ETS adapter keeps atoms).
  defp tool_result_status(%{ok: true}), do: :ok
  defp tool_result_status(%{"ok" => true}), do: :ok
  defp tool_result_status(_result), do: :error

  # Provider opts: hand the tool schemas through (the loop dispatches them itself).
  defp stream_opts(%Config{tools: []}), do: []
  defp stream_opts(%Config{tools: tools}), do: [tools: Tool.to_reqllm(tools)]

  ## Recovery

  # Decide the initial state on (re)start. A conversation killed while suspended on a
  # tool call (HITL) must come back in `:awaiting_input` with its in-memory `calls` map
  # rebuilt from the durable records, so a post-kill `Agentix.resolve/4` is accepted
  # rather than returning `{:error, :stale}`. Otherwise fall back to log-tail recovery.
  defp revive(data, events) do
    case Persistence.pending_tool_calls(data.conversation_id) do
      [] ->
        reconcile_dangling(data, events)

      pending ->
        revive_awaiting(data, pending)
    end
  end

  # A `:tool_call` event with no paired `:tool_result` is dangling: an auto-server tool
  # killed mid-run, or a HITL call the durable expiry resolved while the agent was dead.
  # Providers reject orphan tool calls, so restore the pairing before anything else —
  # then fall through to ordinary tail recovery. We do NOT re-execute a side-effecting
  # tool (that needs an idempotency contract Agentix doesn't model yet); we record the
  # durable terminal result if one exists, else an interrupted error the model can retry.
  defp reconcile_dangling(data, events) do
    case dangling_tool_calls(events) do
      [] ->
        {state, actions} = recover(events)
        {state, data, actions}

      dangling ->
        data = Enum.reduce(dangling, data, &reconcile_one/2)
        {:idle, data, []}
    end
  end

  defp dangling_tool_calls(events) do
    resulted =
      for %Event{type: :tool_result, content: c} <- events,
          into: MapSet.new(),
          do: c["tool_call_id"] || c[:tool_call_id]

    for %Event{type: :tool_call, content: c} <- events,
        id = c["tool_call_id"] || c[:tool_call_id],
        not MapSet.member?(resulted, id),
        do: {id, c["name"] || c[:name]}
  end

  defp reconcile_one({id, name}, data) do
    {:ok, seq} =
      append_event(data, :tool_result, %{
        "tool_call_id" => id,
        "name" => name,
        "result" => reconciled_result(id)
      })

    %{data | last_seq: seq}
  end

  # Prefer a durable terminal result (e.g. the durable expiry already resolved it);
  # otherwise the call was interrupted mid-run.
  defp reconciled_result(id) do
    case Persistence.get_tool_call(id) do
      %{status: status, result: result}
      when status in [:resolved, :errored, :expired] and not is_nil(result) ->
        result

      _ ->
        %{ok: false, error: "tool call interrupted: agent restarted before it completed"}
    end
  end

  # Rebuild the suspended turn: a `calls` entry per still-pending tool call, with the
  # `phase` restored so `handle_resolve/6` accepts the resolution. The pending records are
  # authoritative for *which* calls are open + their args; the `fsm_state.pending` cache
  # supplies each call's display name and `kind` (→ phase).
  defp revive_awaiting(data, pending) do
    cached = fsm_pending(data.conversation_id)
    # Set the turn first so `arm_timeout/2` can key the re-armed timer on its `ref`.
    data = %{data | turn: base_turn(Scope.system())}

    calls =
      Map.new(pending, fn call ->
        meta = Map.get(cached, call.id, %{})
        # The durable record is authoritative; the fsm_state cache is the fallback.
        name = Map.get(call, :name) || meta[:name]
        phase = revive_phase(data.config, name, meta, call)
        # Re-arm the in-process timeout (the durable backstop from the original suspend is
        # still scheduled); without this a revived suspended call would never time out.
        timer = arm_timeout(data, call.id)
        {call.id, call_entry(find_tool(data.config, name), name, call.args, phase, timer: timer)}
      end)

    {:awaiting_input, %{data | turn: %{data.turn | calls: calls}}, []}
  end

  defp fsm_pending(conversation_id) do
    case Persistence.get_conversation(conversation_id) do
      %{fsm_state: %{pending: pending}} when is_map(pending) -> pending
      _ -> %{}
    end
  end

  # Prefer the live tool definition (covers gated re-dispatch); else the cached `kind`;
  # else the executor's default suspension phase.
  defp revive_phase(config, name, meta, call) do
    cond do
      tool = find_tool(config, name) -> suspend_phase(tool)
      meta[:kind] -> kind_to_phase(meta[:kind])
      true -> executor_phase(call.executor)
    end
  end

  defp kind_to_phase(:approval), do: :awaiting_approval
  defp kind_to_phase(:client_exec), do: :awaiting_exec
  defp kind_to_phase(_elicitation), do: :awaiting_human

  defp executor_phase(:client), do: :awaiting_exec
  defp executor_phase(_executor), do: :awaiting_human

  # A log ending in a `:user_msg` was killed after recording the message but before
  # the assistant reply — re-run the turn under the system scope. Any other tail is
  # already resolved.
  defp recover([]), do: {:idle, []}

  defp recover(events) do
    case List.last(events) do
      %Event{type: :user_msg} ->
        {:idle, [{:next_event, :internal, {:rerun, Scope.system()}}]}

      _ ->
        {:idle, []}
    end
  end

  ## Audit (model_calls — off unless enabled)

  defp maybe_audit(data, _message, usage) do
    if audit?(data.config) do
      seq = data.model_call_seq + 1

      Persistence.put_model_call(data.conversation_id, %{
        turn_ref: seq,
        rendered_context: encode_context(data.turn.context),
        model: data.config.model,
        usage: usage || %{}
      })

      %{data | model_call_seq: seq}
    else
      data
    end
  end

  defp audit?(%Config{audit?: true}), do: true
  defp audit?(_config), do: Application.get_env(:agentix, :audit, false)

  # Restore the per-model-call counter on revival so audit rows keyed by `turn_ref`
  # are appended after the pre-crash rows instead of overwriting them. Only the audit
  # table is consulted, and only when audit is on (it is empty otherwise).
  defp last_model_call_seq(conversation_id, config) do
    if audit?(config) do
      conversation_id
      |> Persistence.model_calls()
      |> Enum.map(& &1.turn_ref)
      |> Enum.max(fn -> 0 end)
    else
      0
    end
  end

  ## Helpers

  defp append_event(data, type, content) do
    Persistence.append_event(
      data.conversation_id,
      Event.new(type, content, conversation_id: data.conversation_id)
    )
  end

  # Store the message in its canonical JSON-decoded (string-keyed) form so the ETS
  # and Ecto adapters round-trip identically through `Agentix.Codec`.
  defp message_content(%Message{} = message),
    do: %{"message" => Jason.decode!(Codec.encode!(message))}

  defp encode_context(nil), do: %{}
  defp encode_context(%Context{} = context), do: Jason.decode!(Codec.encode!(context))

  defp normalize_user_message(%Message{} = message), do: message
  defp normalize_user_message(text) when is_binary(text), do: Context.user(text)

  defp put_msg_id(%Message{metadata: metadata} = message, msg_id),
    do: %{message | metadata: Map.put(metadata || %{}, "id", msg_id)}

  defp new_msg_id, do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp fsm_state(state, last_seq), do: %{state: state, pending: %{}, last_seq: last_seq}

  defp max_seq(summary, events) do
    event_max = events |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
    summary_to = if summary, do: summary.to_seq, else: 0
    max(event_max, summary_to)
  end

  defp resolve_config(conversation_id, opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> {:ok, config}
      nil -> resolve_config_from_settings(conversation_id)
    end
  end

  defp resolve_config_from_settings(conversation_id) do
    case Persistence.get_conversation(conversation_id) do
      %{settings: settings} when is_map(settings) and map_size(settings) > 0 ->
        {:ok, Config.new(settings)}

      _ ->
        :error
    end
  end
end
