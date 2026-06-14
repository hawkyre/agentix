defmodule Agentix.Notifier.None do
  @moduledoc """
  A no-op `Agentix.Notifier` for consumers who want zero pub/sub.

  Canonical events still log; only the live event plane is silenced. Select with
  `config :agentix, :notifier, Agentix.Notifier.None`.
  """

  @behaviour Agentix.Notifier

  @impl true
  def broadcast(_pubsub, _topic, _message), do: :ok
end
