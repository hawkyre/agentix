defmodule Agentix.Notifier do
  @moduledoc """
  The seam for the **live event plane** — the lossy, never-canonical stream of
  deltas, state changes, and progress the renderer projects.

  Canonical history is the event log (`Agentix.Persistence`); the notifier carries
  only the live tail. Two implementations ship:

    * `Agentix.Notifier.PubSub` (default) — broadcasts over `Phoenix.PubSub`, the
      backbone for every transport (LiveView, SSE, channel, JSON).
    * `Agentix.Notifier.None` — a no-op for a truly minimal consumer who wants zero
      pub/sub (canonical events still log; only the live plane is silenced).

  Configure with `config :agentix, :notifier, Agentix.Notifier.None`. The `pubsub`
  argument is the registered `Phoenix.PubSub` name (resolved per conversation from
  config, defaulting to `Agentix.PubSub`, which the application starts).
  """

  @typedoc "The registered `Phoenix.PubSub` name, or `nil` for notifiers that need none."
  @type pubsub :: atom() | nil

  @doc """
  Broadcasts `message` to `topic` over `pubsub`. Always returns `:ok` — a dropped
  live event must never become an error (the canonical log is the source of truth).
  """
  @callback broadcast(pubsub(), topic :: String.t(), message :: term()) :: :ok

  @default_impl Agentix.Notifier.PubSub

  @doc "The configured notifier implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:agentix, :notifier, @default_impl)

  @doc "Broadcasts via the configured notifier."
  @spec broadcast(pubsub(), String.t(), term()) :: :ok
  def broadcast(pubsub, topic, message), do: impl().broadcast(pubsub, topic, message)
end
