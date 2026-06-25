defmodule Agentix.Notifier.PubSub do
  @moduledoc """
  The default `Agentix.Notifier` — broadcasts live events over `Phoenix.PubSub`.

  The `pubsub` name is the host's registered `Phoenix.PubSub` (or `Agentix.PubSub`,
  which the Agentix application starts when the host provides none). A missing pub/sub
  process raises a clear configuration error rather than a cryptic `:noproc`.
  """

  @behaviour Agentix.Notifier

  @impl true
  def broadcast(pubsub, topic, message) when is_atom(pubsub) and not is_nil(pubsub) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
    :ok
  rescue
    ArgumentError ->
      reraise """
              Agentix.Notifier.PubSub is configured but no Phoenix.PubSub process is \
              registered under #{inspect(pubsub)}. Start one in your supervision tree \
              (e.g. `{Phoenix.PubSub, name: #{inspect(pubsub)}}`) and set \
              `config :agentix, :pubsub, #{inspect(pubsub)}`, or set \
              `config :agentix, :notifier, Agentix.Notifier.None` to disable the live plane.\
              """,
              __STACKTRACE__
  end
end
