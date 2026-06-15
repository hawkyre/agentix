defmodule Agentix.Conversation do
  @moduledoc """
  The public entry points for driving a conversation.

  `ensure_started/2` is the **only** addressing point: it returns the live agent
  (via `Agentix.Registry`) or starts and rehydrates one under
  `Agentix.ConversationSupervisor`. Both new messages and resolutions enter through
  it, so a conversation killed mid-flight is revived transparently on the next call.

  A conversation is single-in-flight: a `send_message/3` while a turn is running
  returns `{:error, :busy}`.
  """

  alias Agentix.Agent
  alias Agentix.Scope

  @typedoc "A user message — plain text or a prebuilt `ReqLLM.Message`."
  @type message :: String.t() | ReqLLM.Message.t()

  @doc """
  Returns the running agent for `conversation_id`, starting one if absent.

  For a brand-new conversation pass `config: %Agentix.Conversation.Config{}`. On
  revival the config is rebuilt from the persisted settings, so `:config` may be
  omitted; without either, `{:error, :unknown_conversation}` is returned.
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(conversation_id, opts \\ []) when is_binary(conversation_id) do
    case Registry.lookup(Agentix.Registry, conversation_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_agent(conversation_id, opts)
    end
  end

  @doc """
  Sends a user `message` to the conversation under `scope`, starting the agent if
  needed (pass `config:` in `opts` for a new conversation). Returns `:ok` once the
  turn is accepted, or `{:error, :busy}` if a turn is already in flight.
  """
  @spec send_message(String.t(), message(), Scope.t(), keyword()) :: :ok | {:error, term()}
  def send_message(conversation_id, message, %Scope{} = scope, opts \\ []) do
    with {:ok, _pid} <- ensure_started(conversation_id, opts) do
      :gen_statem.call(Agent.via(conversation_id), {:send_message, message, scope})
    end
  end

  @doc "Cancels the in-flight turn from any non-idle state. A no-op if not running."
  @spec cancel(String.t()) :: :ok
  def cancel(conversation_id) do
    case Registry.lookup(Agentix.Registry, conversation_id) do
      [{_pid, _}] -> :gen_statem.call(Agent.via(conversation_id), :cancel)
      [] -> :ok
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
        {:ok, pid}

      {:error, reason} when reason in [:unknown_conversation, {:shutdown, :unknown_conversation}] ->
        {:error, :unknown_conversation}

      :ignore ->
        {:error, :ignore}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
