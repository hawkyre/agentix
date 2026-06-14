defmodule Agentix.Agent do
  @moduledoc """
  The per-conversation agent — one `:gen_statem` process per conversation, addressed
  through `Agentix.Registry` and started under `Agentix.ConversationSupervisor`.

  ## States (v0 turn loop)

      idle ──send_message──> preparing ──assembled──> streaming ──done──> idle
      any non-idle ──cancel──> idle (records a partial assistant turn)

  `executing_tools` and `awaiting_input` join in Inc 6 (tools / HITL). Callback mode
  is `:state_functions`.

  ## Non-blocking principle

  The process never blocks on I/O. The LLM stream runs in a **monitored task**
  (under `Agentix.TaskSupervisor`); chunks arrive as `{:chunk, …}` messages,
  completion as `{:stream_done, …}`, failure surfaces via the task's `DOWN`. Inside
  the agent only bookkeeping happens (append to the log, broadcast a live event,
  pick the next transition), so `cancel`/`inspect` are always serviceable.

  ## Durability

  The append-only event log (`Agentix.Persistence`) is the source of truth; the
  agent rebuilds its working context from the log every turn and re-reads the max
  `seq` on revival (D9). On `ensure_started` a log ending in a dangling `:user_msg`
  (killed mid-stream, nothing dispatched) is **re-run** — no side effects happened.
  """

  @behaviour :gen_statem

  alias Agentix.Codec
  alias Agentix.Conversation.Config
  alias Agentix.Event
  alias Agentix.Events.Publisher
  alias Agentix.Persistence
  alias Agentix.Provider
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  require Logger

  defmodule Data do
    @moduledoc false
    # FSM data. `turn` is `nil` outside a turn and a map while preparing/streaming:
    # `%{ref, msg_id, scope, task_pid, monitor_ref, cancel, text, thinking}`.
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
        Persistence.put_conversation(conversation_id, %{settings: settings_of(config)})
        {summary, events} = Persistence.load_since(conversation_id)
        last_seq = max_seq(summary, events)

        data = %Data{
          conversation_id: conversation_id,
          config: config,
          publisher: Publisher.new(config, conversation_id),
          last_seq: last_seq
        }

        {state, actions} = recover(events)
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

  def idle(:internal, {:rerun, message, scope}, data) do
    start_turn(message, scope, data, nil)
  end

  def idle(event_type, event, data), do: handle_common(:idle, event_type, event, data)

  ## State: preparing — assemble context and launch the streaming task

  def preparing(:internal, :assemble, data) do
    context = assemble_context(data)
    turn = data.turn
    agent = self()
    model = data.config.model
    opts = stream_opts(data.config)

    %{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(Agentix.TaskSupervisor, fn ->
        run_stream(agent, turn.ref, model, context, opts)
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

  ## Shared handlers

  # Stale messages from a superseded turn (different ref) are dropped — the mailbox
  # may still hold chunks from a turn that was cancelled.
  defp handle_common(_state, :info, {tag, _ref, _a, _b}, _data)
       when tag in [:stream_started, :chunk, :stream_done, :stream_error] do
    :keep_state_and_data
  end

  defp handle_common(_state, :info, {tag, _ref, _a}, _data)
       when tag in [:stream_started, :chunk, :stream_error] do
    :keep_state_and_data
  end

  defp handle_common(_state, :info, {:DOWN, _ref, :process, _pid, _reason}, _data) do
    :keep_state_and_data
  end

  defp handle_common(_state, _event_type, _event, _data), do: :keep_state_and_data

  ## Turn lifecycle

  defp start_turn(message, scope, data, from) do
    user_message = normalize_user_message(message)
    {:ok, seq} = append_event(data, :user_msg, message_content(user_message))

    turn = %{
      ref: make_ref(),
      msg_id: new_msg_id(),
      scope: scope,
      task_pid: nil,
      monitor_ref: nil,
      cancel: nil,
      context: nil,
      text: "",
      thinking: ""
    }

    data = %{data | last_seq: seq, turn: turn}
    Publisher.turn_started(data.publisher, turn.ref)
    Publisher.state_changed(data.publisher, :preparing)

    reply = if from, do: [{:reply, from, :ok}], else: []
    {:next_state, :preparing, data, reply ++ [{:next_event, :internal, :assemble}]}
  end

  defp complete_turn(message, usage, data) do
    turn = data.turn
    message = put_msg_id(message, turn.msg_id)
    {:ok, seq} = append_event(data, :assistant_msg, message_content(message))
    data = maybe_audit(%{data | last_seq: seq}, message, usage)

    Publisher.message_completed(data.publisher, turn.ref, message)
    Publisher.turn_completed(data.publisher, turn.ref)

    :telemetry.execute(
      [:agentix, :turn, :stop],
      %{},
      %{conversation_id: data.conversation_id, turn_ref: turn.ref}
    )

    finish(data, :idle)
  end

  # The stream failed (provider error or task crash). Record the partial text we did
  # receive (if any) so the log keeps a faithful assistant turn, then return to idle.
  defp fail_turn(reason, data) do
    turn = data.turn
    Logger.warning("agentix stream failed: #{inspect(reason)}")

    data = record_partial(data, " [stream error]")
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

    if turn.monitor_ref, do: Process.demonitor(turn.monitor_ref, [:flush])
    if turn.task_pid, do: Task.Supervisor.terminate_child(Agentix.TaskSupervisor, turn.task_pid)
    if is_function(turn.cancel, 0), do: turn.cancel.()

    data = record_partial(data, " [cancelled]")
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
  # every turn leaves a paired record. `suffix` marks why it is partial.
  defp record_partial(data, suffix) do
    turn = data.turn
    text = turn.text <> suffix

    message =
      put_msg_id(
        %Message{role: :assistant, content: [ContentPart.text(text)]},
        turn.msg_id
      )

    {:ok, seq} = append_event(data, :assistant_msg, message_content(message))
    %{data | last_seq: seq}
  end

  defp finish(data, state) do
    Persistence.put_fsm_state(data.conversation_id, fsm_state(state, data.last_seq))
    Publisher.state_changed(data.publisher, state)
    {:next_state, state, %{data | turn: nil}}
  end

  ## Streaming task (runs under Agentix.TaskSupervisor)

  defp run_stream(agent, turn_ref, model, context, opts) do
    case Provider.stream(model, context, opts) do
      {:ok, stream} ->
        send(agent, {:stream_started, turn_ref, stream.cancel})
        Enum.each(stream.chunks, fn chunk -> send(agent, {:chunk, turn_ref, chunk}) end)
        {message, usage} = stream.finalize.()
        send(agent, {:stream_done, turn_ref, message, usage})

      {:error, reason} ->
        send(agent, {:stream_error, turn_ref, reason})
    end
  end

  defp handle_chunk(%{type: :content, text: text} = _chunk, data) when is_binary(text) do
    turn = data.turn
    Publisher.text_delta(data.publisher, turn.ref, turn.msg_id, text)
    put_in(data.turn.text, turn.text <> text)
  end

  defp handle_chunk(%{type: :thinking, text: text} = _chunk, data) when is_binary(text) do
    turn = data.turn
    Publisher.thinking_delta(data.publisher, turn.ref, turn.msg_id, text)
    put_in(data.turn.thinking, turn.thinking <> text)
  end

  # :tool_call chunks carry no id (harvested post-stream in Inc 6); :meta is noise.
  defp handle_chunk(_chunk, data), do: data

  ## Context assembly (hooks/compaction plug in here — Inc 7/8)

  defp assemble_context(data) do
    history =
      data.conversation_id
      |> Persistence.stream_events()
      |> Enum.filter(&(&1.type in [:user_msg, :assistant_msg]))
      |> Enum.map(&decode_event_message/1)

    system =
      case data.config.system_prompt do
        nil -> []
        "" -> []
        prompt -> [Context.system(prompt)]
      end

    Context.new(system ++ history)
  end

  defp decode_event_message(%Event{content: content}) do
    Codec.decode_message(content["message"] || content[:message])
  end

  ## Recovery

  defp recover([]), do: {:idle, []}

  defp recover(events) do
    case List.last(events) do
      %Event{type: :user_msg, content: content} ->
        message = Codec.decode_message(content["message"] || content[:message])
        {:idle, [{:next_event, :internal, {:rerun, message, Agentix.Scope.system()}}]}

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

  defp stream_opts(%Config{} = _config), do: []

  defp resolve_config(_conversation_id, opts) when is_list(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> {:ok, config}
      nil -> resolve_config_from_settings(Keyword.fetch!(opts, :conversation_id))
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

  defp settings_of(%Config{} = config), do: Map.from_struct(config)
end
