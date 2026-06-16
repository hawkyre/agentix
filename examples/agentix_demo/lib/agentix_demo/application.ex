defmodule AgentixDemo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentixDemo.Repo,
      # Tier 3 — Oban owns the durable suspension-expiry timers Agentix schedules.
      {Oban, Application.fetch_env!(:agentix_demo, Oban)},
      AgentixDemoWeb.Endpoint
    ]

    # Agentix's own application (a dependency) already started its registry, task
    # supervisor, and `Agentix.PubSub` — this tree only owns the host's Repo, Oban, and web.
    Supervisor.start_link(children, strategy: :one_for_one, name: AgentixDemo.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentixDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
