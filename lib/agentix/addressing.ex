defmodule Agentix.Addressing do
  @moduledoc """
  How a conversation id resolves to its running agent.

  Two modes, chosen with `config :agentix, :addressing`:

    * `:local` (default) — a node-local `Registry`. An agent is reachable only
      from the node running it.
    * `:global` — Erlang's `:global` name registry, so a conversation resolves
      the same way from every node in the cluster.

  ## Which one you need

  `:local` is correct for a single node and wrong for more than one, in a way
  that does not announce itself. A conversation is meant to have exactly one
  agent, because that agent is the single writer of its durable log. Under
  `:local` on two nodes, each node's `ensure_started/2` finds nothing locally
  and starts its own, so two agents interleave writes to the same conversation.
  Cancelling has the mirror problem: the cancel resolves nothing on the calling
  node and returns `:ok` having done nothing at all.

  Under `:global` the name is cluster-wide, so the second node's start loses
  with `{:error, {:already_started, pid}}` — which `Agentix.Conversation`
  already handles — and every entry verb reaches the one live agent wherever it
  runs.

  ## What `:global` costs

  Registration is a cluster-wide synchronous operation, so starting a
  conversation is slower and gets slower as nodes are added. It suits workloads
  where conversations are coarse (a chat session, an extraction run) rather than
  one per request.

  A netsplit is the case `:global` does not solve. Both sides register their own
  agent, both write, and on heal `:global` resolves the duplicate name by
  killing one — after both have written. If that matters, the durable log is the
  place to settle it, not the registry.
  """

  @registry Agentix.Registry

  @typedoc "The addressing mode in effect."
  @type mode() :: :local | :global

  @doc """
  The configured mode.
  """
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:agentix, :addressing, :local) do
      :global -> :global
      _local -> :local
    end
  end

  @doc """
  The `via` tuple a conversation's agent is registered and addressed under.
  """
  @spec via(String.t()) :: {:via, module(), term()}
  def via(conversation_id) do
    case mode() do
      :global -> {:via, :global, global_name(conversation_id)}
      :local -> {:via, Registry, {@registry, conversation_id}}
    end
  end

  @doc """
  The pid running `conversation_id`, or `:error` when none is registered.
  """
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(conversation_id) do
    case mode() do
      :global -> from_global(:global.whereis_name(global_name(conversation_id)))
      :local -> from_registry(Registry.lookup(@registry, conversation_id))
    end
  end

  @spec global_name(String.t()) :: {module(), String.t()}
  defp global_name(conversation_id), do: {__MODULE__, conversation_id}

  @spec from_global(pid() | :undefined) :: {:ok, pid()} | :error
  defp from_global(pid) when is_pid(pid), do: {:ok, pid}
  defp from_global(:undefined), do: :error

  @spec from_registry([{pid(), term()}]) :: {:ok, pid()} | :error
  defp from_registry([{pid, _value} | _rest]), do: {:ok, pid}
  defp from_registry([]), do: :error
end
