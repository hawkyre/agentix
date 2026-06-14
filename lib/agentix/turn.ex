defmodule Agentix.Turn do
  @moduledoc """
  The context object threaded through a turn's hook and tool pipeline (`.docs/02`).

  Hooks and `:server` tools receive and return this thin struct rather than a bare
  `ReqLLM.Context`, so ambient state (`scope`) lives in one place:

    * `context` — the conversation so far (a `ReqLLM.Context`).
    * `user_message` — the message that opened this turn (a `ReqLLM.Message`).
    * `turn_ref` — correlates live events and the optional audit record.
    * `scope` — an `Agentix.Scope` (current user, etc.).

  `context` and `user_message` are held opaquely here to avoid coupling the core
  type to ReqLLM struct internals; the agent populates them with ReqLLM values.
  """

  alias Agentix.Scope

  @type t :: %__MODULE__{
          context: term(),
          user_message: term(),
          turn_ref: term(),
          scope: Scope.t()
        }

  defstruct context: nil, user_message: nil, turn_ref: nil, scope: nil

  @doc """
  Builds a turn from `attrs`. `:scope` defaults to a fresh `Agentix.Scope`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = Map.new(attrs)

    %__MODULE__{
      context: Map.get(attrs, :context),
      user_message: Map.get(attrs, :user_message),
      turn_ref: Map.get(attrs, :turn_ref),
      scope: Map.get(attrs, :scope) || Scope.new()
    }
  end
end
