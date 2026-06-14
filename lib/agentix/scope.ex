defmodule Agentix.Scope do
  @moduledoc """
  Ambient runtime state for a turn — Phoenix 1.8 `Scope`-style.

  Carries the current user and any app-supplied `assigns`, and is the context
  argument `:server` tools and hooks receive. It is **not** persisted; it is
  supplied per entry call (`.docs/04`). Timeout-driven resolutions run with the
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
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = Map.new(attrs)

    %__MODULE__{
      current_user: Map.get(attrs, :current_user),
      system?: Map.get(attrs, :system?, false),
      assigns: Map.get(attrs, :assigns, %{})
    }
  end

  @doc "The documented system scope used by timeout-driven resolutions."
  @spec system() :: t()
  def system, do: %__MODULE__{system?: true}
end
