defmodule Agentix.Turn do
  @moduledoc """
  The per-turn context handed to `:server` tool callbacks and to hooks.

  A turn carries the assembled `context` sent to the model, the `user_message` that
  opened the turn, an opaque `turn_ref`, and the `scope` of the caller who is acting
  this turn. The scope is **enforced** — a turn always carries one (system scope for
  timeout/recovery-driven turns).

  Two fields serve the hook pipeline: `injections` accumulates the
  `ContentPart`s a pre-hook adds (appended at the context tail at assembly time, via
  `Agentix.Hook.inject/2`), and `assistant_message` carries the finalized message to a
  post-hook (`nil` for pre-hooks and tool callbacks).

  Built with `new/1`; rejects unknown keys.
  """

  alias Agentix.Scope

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t() | nil,
          user_message: ReqLLM.Message.t() | nil,
          assistant_message: ReqLLM.Message.t() | nil,
          turn_ref: term(),
          scope: Scope.t(),
          injections: [ReqLLM.Message.ContentPart.t()]
        }

  @enforce_keys [:scope]
  defstruct context: nil,
            user_message: nil,
            assistant_message: nil,
            turn_ref: nil,
            scope: nil,
            injections: []

  @doc """
  Builds a turn from `attrs`. Requires a `%Agentix.Scope{}` under `:scope`. Raises
  `ArgumentError` on unknown keys or a missing/invalid scope.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    turn = struct!(__MODULE__, attrs)
    validate_scope!(turn.scope)
    turn
  end

  defp validate_scope!(%Scope{}), do: :ok

  defp validate_scope!(other) do
    raise ArgumentError, "Agentix.Turn requires a %Agentix.Scope{} :scope, got: #{inspect(other)}"
  end
end
