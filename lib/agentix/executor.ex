defmodule Agentix.Executor do
  @moduledoc """
  The executor axis of a tool — who produces a tool call's result.

  The set is closed and small (`.docs/03`):

    * `:server` — your code runs it and returns a result (the default).
    * `:human` — the human is the executor; their answer is the result (elicitation).
    * `:client` — runs in the browser/LiveView over the socket.
    * `:provider` — the provider executes it; the result returns in the stream.

  Keeping the enum closed is deliberate: when set-theoretic type syntax lands
  (~Elixir 1.22) this becomes a declared, exhaustiveness-checked union.
  """

  @executors [:server, :human, :client, :provider]

  @type t :: :server | :human | :client | :provider

  @doc "All valid executors."
  @spec all() :: [t()]
  def all, do: @executors

  @doc "Returns `true` if `value` is a valid executor."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @executors

  @doc """
  Returns `executor` unchanged, raising `ArgumentError` if it is not valid.
  """
  @spec validate!(term()) :: t()
  def validate!(executor) when executor in @executors, do: executor

  def validate!(other) do
    raise ArgumentError,
          "invalid executor #{inspect(other)}; expected one of #{inspect(@executors)}"
  end
end
