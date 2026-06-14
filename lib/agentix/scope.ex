defmodule Agentix.Scope do
  @moduledoc """
  Ambient runtime state for a turn — Phoenix 1.8 `Scope`-style.

  Carries the current user and any app-supplied `assigns`, and is the context
  argument `:server` tools and hooks receive. It is **not** persisted; it is
  supplied per entry call. Timeout-driven resolutions run with the
  documented system scope (`system/0`), which a tool needing a real user scope
  should reject rather than guess from.
  """

  @type t :: %__MODULE__{
          current_user: term() | nil,
          system?: boolean(),
          assigns: map()
        }

  defstruct current_user: nil, system?: false, assigns: %{}

  @doc """
  Builds a scope from `attrs` (`:current_user`, `:assigns`, `:system?`).

  Raises `ArgumentError` on unknown keys, or if a system scope is given a
  `current_user` (the system scope carries no user by definition).
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    __MODULE__ |> struct!(attrs) |> validate!()
  end

  @doc "The documented system scope used by timeout-driven resolutions."
  @spec system() :: t()
  def system, do: %__MODULE__{system?: true}

  defp validate!(%__MODULE__{system?: true, current_user: user}) when not is_nil(user) do
    raise ArgumentError, "a system scope cannot carry a :current_user"
  end

  defp validate!(%__MODULE__{} = scope), do: scope
end
