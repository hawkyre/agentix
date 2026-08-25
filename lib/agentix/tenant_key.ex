defmodule Agentix.TenantKey do
  @moduledoc false
  # The tenant-key rules, in one place: the format check shared by
  # `Conversation.Config`, `Scope`, and the entry verbs, and the write-once merge
  # used at both resolution steps in `Agentix.Agent`. One deliberate outlier
  # remains: `Conversation`'s running-agent check is stricter than `merge/2`
  # (a running agent cannot be late-keyed) and documents why at its own site.

  # Chosen cap, not derived from a requirement: it only needs to sit well under
  # Postgres's ~2704-byte btree index-entry ceiling, past which the indexed
  # column write raises inside agent init instead of failing validation here.
  @max_bytes 255

  @doc "Raises unless `key` is nil or a non-empty string of at most #{@max_bytes} bytes."
  @spec validate!(term()) :: :ok
  def validate!(nil), do: :ok

  def validate!(key) when is_binary(key) and key != "" and byte_size(key) <= @max_bytes, do: :ok

  def validate!(other) do
    raise ArgumentError,
          "tenant_key must be nil or a 1..#{@max_bytes}-byte string, got: #{inspect(other)}"
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
