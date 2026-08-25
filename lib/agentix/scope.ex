defmodule Agentix.Scope do
  @moduledoc """
  The caller's authorization/context, passed per entry-verb call (`send_message/3`,
  `resolve/4`) and threaded into `:server` tool callbacks via `Agentix.Turn`.

  A scope is **per-call and never persisted** — it reflects who is acting *now*, not
  conversation state. Two flavours:

    * a **user** scope — carries `current_user` and arbitrary `assigns`;
    * a **system** scope (`system/0`) — `system?: true`, the documented scope for
      timeout-driven resolutions and other server-initiated actions. A system scope
      may not carry a `current_user`.

  Built with `new/1` (rejects unknown keys).

  ## Optional fields

    * `tenant_key` — the acting tenant, for multi-tenant hosts (`nil` or a
      non-empty string). Entry verbs (`send_message/4`, `resolve/4`) use it as the
      default `tenant_key:` option when the caller passes none, so authenticating
      the tenant into the scope is enough to get the write-once isolation check on
      every call (an explicit option still wins). The conversation's own persisted
      tenant is `Agentix.Conversation.Config.tenant_key`. Like the rest of the
      scope, this field itself is never persisted and never broadcast on telemetry.
  """

  alias Agentix.TenantKey

  @type t :: %__MODULE__{
          current_user: term() | nil,
          assigns: map(),
          system?: boolean(),
          tenant_key: String.t() | nil
        }

  defstruct current_user: nil, assigns: %{}, system?: false, tenant_key: nil

  @doc """
  Builds a scope from `attrs`. Raises `ArgumentError` on unknown keys, if `assigns`
  is not a map, or if a system scope carries a `current_user`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    scope = struct!(__MODULE__, attrs)
    validate_assigns!(scope.assigns)
    validate_system!(scope)
    TenantKey.validate!(scope.tenant_key)
    scope
  end

  @doc "The documented system scope (e.g. timeout-driven resolutions)."
  @spec system() :: t()
  def system, do: %__MODULE__{system?: true}

  defp validate_assigns!(assigns) when is_map(assigns), do: :ok

  defp validate_assigns!(other) do
    raise ArgumentError, "Agentix.Scope :assigns must be a map, got: #{inspect(other)}"
  end

  defp validate_system!(%__MODULE__{system?: true, current_user: user}) when not is_nil(user) do
    raise ArgumentError, "a system Agentix.Scope may not carry a :current_user"
  end

  defp validate_system!(_scope), do: :ok
end
