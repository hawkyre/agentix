defmodule Agentix.TenantKey do
  @moduledoc false
  # The tenant-key rules, in one place: the format check shared by
  # `Conversation.Config`, `Scope`, and the entry verbs, and the write-once merge
  # used at both resolution steps in `Agentix.Agent`. Neither struct owns the other,
  # and the rule cannot drift between call sites.

  @doc "Raises unless `key` is nil or a non-empty string."
  @spec validate!(term()) :: :ok
  def validate!(nil), do: :ok
  def validate!(key) when is_binary(key) and key != "", do: :ok

  def validate!(other) do
    raise ArgumentError, "tenant_key must be nil or a non-empty string, got: #{inspect(other)}"
  end

  @doc """
  Write-once merge of a requested key onto an existing one: an unkeyed side defers
  to the keyed one, equal keys pass through, and two different keys are a conflict.
  """
  @spec merge(String.t() | nil, String.t() | nil) :: {:ok, String.t() | nil} | :error
  def merge(nil, existing), do: {:ok, existing}
  def merge(requested, existing) when existing in [nil, requested], do: {:ok, requested}
  def merge(_requested, _existing), do: :error
end
