defmodule Agentix.Conversation do
  @moduledoc """
  The public entry points for driving a conversation.

  `ensure_started/2` is the **only** addressing point: it returns the live agent
  (via `Agentix.Addressing`) or starts and rehydrates one under
  `Agentix.ConversationSupervisor`. Both new messages and resolutions enter through
  it, so a conversation killed mid-flight is revived transparently on the next call.

  A conversation is single-in-flight: a `send_message/3` while a turn is running
  returns `{:error, :busy}`.
  """

  alias Agentix.Agent
  alias Agentix.Scope
  alias Agentix.TenantKey

  @typedoc "A user message — plain text or a prebuilt `ReqLLM.Message`."
  @type message :: String.t() | ReqLLM.Message.t()

  @doc """
  Returns the running agent for `conversation_id`, starting one if absent.

  For a brand-new conversation pass `config: %Agentix.Conversation.Config{}`. On
  revival the config is rebuilt from the persisted settings, so `:config` may be
  omitted; without either, `{:error, :unknown_conversation}` is returned.

  `tenant_key: "acme"` sets the conversation's owning tenant (see
  `Agentix.Conversation.Config`). Write-once: setting it when the conversation
  starts (or revives) unkeyed, and re-passing the same value, is fine; a
  conflicting value returns `{:error, :tenant_key_conflict}`. Keying a currently
  **running** unkeyed conversation is also a conflict — stop the agent first so
  the key applies on revival.
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(conversation_id, opts \\ []) when is_binary(conversation_id) do
    tenant_opt = Keyword.get(opts, :tenant_key)
    TenantKey.validate!(tenant_opt)

    case lookup_agent(conversation_id) do
      {:ok, pid} -> check_running_tenant(conversation_id, opts, pid)
      :error -> start_agent(conversation_id, opts)
    end
  end

  # The agent is already running, so a tenant_key opt can no longer change anything —
  # it must match the agent's key exactly. Deliberately stricter than
  # `Agentix.TenantKey.merge/2`: a running agent's in-memory config cannot be
  # re-keyed, so late-keying a running unkeyed conversation is refused too.
  #
  # The key is read from the live process, not the persisted record: the Registry
  # name registers before `init/1` runs, so a durable read here can race a
  # still-initializing winner (observing nil and manufacturing a spurious
  # conflict); a `:gen_statem.call` queues behind init and always sees the
  # resolved key.
  defp check_running_tenant(conversation_id, opts, pid) do
    case Keyword.get(opts, :tenant_key) do
      nil ->
        {:ok, pid}

      key ->
        case :gen_statem.call(Agent.via(conversation_id), :tenant_key) do
          ^key -> {:ok, pid}
          _other -> {:error, :tenant_key_conflict}
        end
    end
  catch
    # The agent exited between discovery and the call — start over; the fresh
    # attempt resolves the key through init's own write-once merge.
    :exit, _reason -> ensure_started(conversation_id, opts)
  end

  @doc """
  Sends a user `message` to the conversation under `scope`, starting the agent if
  needed (pass `config:` in `opts` for a new conversation). Returns `:ok` once the
  turn is accepted, or `{:error, :busy}` if a turn is already in flight.

  Per-turn `opts`:

    * `:schema` — structured output for this turn only. A NimbleOptions keyword or a
      JSON Schema map makes the model return a conforming object (surfaced via
      `Agentix.object/1`); `false` opts out of the conversation's `response_format`
      default for this one turn. Omitting it uses that default (or plain text).

  When `scope` carries a `tenant_key` and `opts` do not, the scope's key is used
  as the call's `tenant_key:` — so a host that authenticates the tenant into the
  scope gets the write-once isolation check on every send without extra plumbing.
  An explicit `tenant_key:` opt always wins.
  """
  @spec send_message(String.t(), message(), Scope.t(), keyword()) :: :ok | {:error, term()}
  def send_message(conversation_id, message, %Scope{} = scope, opts \\ []) do
    turn_opts = Keyword.take(opts, [:schema])
    validate_turn_opts!(turn_opts)
    opts = default_tenant_from_scope(opts, scope)

    with {:ok, _pid} <- ensure_started(conversation_id, opts) do
      :gen_statem.call(Agent.via(conversation_id), {:send_message, message, scope, turn_opts})
    end
  end

  @doc false
  # The scope's tenant doubles as the call's tenant check unless the caller passed
  # an explicit option. Shared with `Agentix.Resolve`.
  @spec default_tenant_from_scope(keyword(), Scope.t()) :: keyword()
  def default_tenant_from_scope(opts, %Scope{tenant_key: nil}), do: opts

  def default_tenant_from_scope(opts, %Scope{tenant_key: key}),
    do: Keyword.put_new(opts, :tenant_key, key)

  # Validate the per-turn `:schema` at the boundary (the config-level default is validated
  # in `Config.new/2`; a per-turn override must meet the same bar, plus `false`/`nil` to opt
  # out). A bad value is a caller error, so raise here rather than crash deep in the provider.
  defp validate_turn_opts!(turn_opts) do
    case Keyword.fetch(turn_opts, :schema) do
      :error -> :ok
      {:ok, schema} -> validate_schema!(schema)
    end
  end

  defp validate_schema!(schema) when schema in [false, nil], do: :ok
  defp validate_schema!(schema) when is_map(schema) and map_size(schema) > 0, do: :ok

  defp validate_schema!(schema) when is_list(schema) and schema != [] do
    if Keyword.keyword?(schema), do: :ok, else: raise(ArgumentError, schema_error(schema))
  end

  defp validate_schema!(schema), do: raise(ArgumentError, schema_error(schema))

  defp schema_error(value),
    do:
      ":schema must be false, nil, a non-empty keyword, or a non-empty map, got: #{inspect(value)}"

  @doc """
  Cancels the in-flight turn from any non-idle state. A no-op if not running.

  Returns once the turn is actually down: the streaming task is terminated, the
  provider's cancel closure has run so the socket is closed, the partial
  assistant message is persisted and the conversation is back to idle.

  Which agents this can reach depends on `Agentix.Addressing`. Under the default
  `:local` mode a turn running on another node is not found, and the call
  returns `:ok` having cancelled nothing.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(conversation_id) do
    case lookup_agent(conversation_id) do
      {:ok, _pid} -> :gen_statem.call(Agent.via(conversation_id), :cancel)
      :error -> :ok
    end
  end

  @doc """
  Stops the conversation's agent process. A no-op when it isn't running.

  The conversation itself is not ended — its persisted events remain, and the next
  `ensure_started/2` revives it (pass `config:` again if the conversation relies on
  non-persisted settings such as `api_key`, tools, or hooks). Use this to release an
  idle agent without losing history.
  """
  @spec stop(String.t()) :: :ok
  def stop(conversation_id) when is_binary(conversation_id) do
    case lookup_agent(conversation_id) do
      {:ok, pid} -> terminate_agent(pid)
      :error -> :ok
    end
  end

  @spec lookup_agent(String.t()) :: {:ok, pid()} | :error
  defp lookup_agent(conversation_id), do: Agentix.Addressing.whereis(conversation_id)

  # The pid can die between lookup and terminate; :not_found is success here.
  @spec terminate_agent(pid()) :: :ok
  defp terminate_agent(pid) do
    case DynamicSupervisor.terminate_child(Agentix.ConversationSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp start_agent(conversation_id, opts) do
    spec = {Agent, [{:conversation_id, conversation_id} | opts]}

    case DynamicSupervisor.start_child(Agentix.ConversationSupervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Lost a start race: this caller's tenant opt must be re-checked against
        # the winner — returning {:ok, pid} blindly would silently discard a
        # conflicting key.
        check_running_tenant(conversation_id, opts, pid)

      {:error, reason} when reason in [:unknown_conversation, {:shutdown, :unknown_conversation}] ->
        {:error, :unknown_conversation}

      {:error, reason} when reason in [:tenant_key_conflict, {:shutdown, :tenant_key_conflict}] ->
        {:error, :tenant_key_conflict}

      :ignore ->
        {:error, :ignore}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
