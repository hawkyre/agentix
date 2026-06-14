defmodule Agentix.Turn do
  @moduledoc """
  The context object threaded through a turn's hook and tool pipeline.

  Hooks and `:server` tools receive and return this thin struct rather than a bare
  `ReqLLM.Context`, so ambient state (`scope`) lives in one place:

    * `context` — the conversation so far (a `ReqLLM.Context`).
    * `user_message` — the message that opened this turn (a `ReqLLM.Message`).
    * `turn_ref` — correlates live events and the optional audit record.
    * `scope` — an `Agentix.Scope` (current user, etc.).

  Always build with `new/1`, which guarantees a `scope` is present (the field is
  enforced). `context` and `user_message` are held opaquely to avoid coupling the
  core type to ReqLLM struct internals; the agent populates them with ReqLLM values.
  """

  alias Agentix.Scope

  @type t :: %__MODULE__{
          context: term(),
          user_message: term(),
          turn_ref: term(),
          scope: Scope.t()
        }

  @enforce_keys [:scope]
  defstruct [:scope, context: nil, user_message: nil, turn_ref: nil]

  @doc """
  Builds a turn from `attrs`. `:scope` defaults to a fresh `Agentix.Scope`; a
  `nil` scope is replaced by the default so a turn always carries one. Raises
  `ArgumentError` on unknown keys.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = Map.new(attrs)
    scope = Map.get(attrs, :scope) || Scope.new()
    struct!(__MODULE__, Map.put(attrs, :scope, scope))
  end
end
