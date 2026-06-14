defmodule Agentix.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Per-conversation agents are addressed through this registry — it is the
        # single addressing point (Registry -> Horde/syn later).
        {Registry, keys: :unique, name: Agentix.Registry}
      ] ++
        persistence_children() ++
        [
          # Conversation agents are started on demand under this supervisor.
          {DynamicSupervisor, strategy: :one_for_one, name: Agentix.ConversationSupervisor}
        ]

    opts = [strategy: :one_for_one, name: Agentix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The ETS adapter needs an owner process for its tables; it must start before
  # the conversation supervisor (agents touch the tables on start). Other adapters
  # (e.g. Ecto) need no owner.
  defp persistence_children do
    if Agentix.Persistence.adapter() == Agentix.Persistence.ETS do
      [Agentix.Persistence.ETS.Owner]
    else
      []
    end
  end
end
