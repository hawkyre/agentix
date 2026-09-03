defmodule Agentix.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Backs `Agentix.Addressing` in `:local` mode. Started unconditionally so
        # the mode can be switched at runtime.
        {Registry, keys: :unique, name: Agentix.Registry},
        # The default live-event backbone. A host that supervises its own
        # `Phoenix.PubSub` sets `config :agentix, :pubsub, MyApp.PubSub` and ignores
        # this one; the default lets a zero-config consumer stream out of the box.
        {Phoenix.PubSub, name: Agentix.PubSub},
        # Monitored streaming/tool tasks run here so the agent never blocks on I/O
        # and a killed task never takes the agent with it.
        {Task.Supervisor, name: Agentix.TaskSupervisor}
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
  # the conversation supervisor (agents touch the tables on start). It starts
  # UNCONDITIONALLY since 0.3.0 so ETS is usable in tests and tooling even when
  # the app-configured adapter is Ecto. Idle empty tables cost nothing.
  defp persistence_children do
    [Agentix.Persistence.ETS.Owner]
  end
end
