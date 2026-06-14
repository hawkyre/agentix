defmodule Agentix.Event do
  @moduledoc """
  A single entry in the canonical, append-only conversation log.

  The log is the source of truth (`.docs/01`, `.docs/04`); everything else is
  derived from it. `seq`, `conversation_id`, and `inserted_at` are assigned by the
  persistence layer on append — an in-memory event built with `new/2` carries them
  as `nil` until then.

  The six `type`s form a closed union: `:user_msg`, `:assistant_msg`,
  `:tool_call`, `:tool_result`, `:suspension`, `:resolution`.
  """

  @types [:user_msg, :assistant_msg, :tool_call, :tool_result, :suspension, :resolution]

  @type type ::
          :user_msg | :assistant_msg | :tool_call | :tool_result | :suspension | :resolution

  @type t :: %__MODULE__{
          type: type(),
          content: map(),
          seq: non_neg_integer() | nil,
          conversation_id: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @enforce_keys [:type, :content]
  defstruct [:type, :content, :seq, :conversation_id, :inserted_at]

  @doc "All valid event types."
  @spec types() :: [type()]
  def types, do: @types

  @doc "Returns `true` if `value` is a valid event type."
  @spec valid_type?(term()) :: boolean()
  def valid_type?(value), do: value in @types

  @doc """
  Builds an event of `type` carrying `content` (a map).

  Optional `:seq`, `:conversation_id`, and `:inserted_at` may be supplied; the
  persistence layer normally assigns them. Raises `ArgumentError` if `type` is not
  one of `types/0` or `content` is not a map.
  """
  @spec new(type(), map(), keyword()) :: t()
  def new(type, content, opts \\ [])

  def new(type, content, opts) when type in @types and is_map(content) do
    %__MODULE__{
      type: type,
      content: content,
      seq: Keyword.get(opts, :seq),
      conversation_id: Keyword.get(opts, :conversation_id),
      inserted_at: Keyword.get(opts, :inserted_at)
    }
  end

  def new(type, content, _opts) when type in @types do
    raise ArgumentError, "event content must be a map, got: #{inspect(content)}"
  end

  def new(type, _content, _opts) do
    raise ArgumentError, "invalid event type #{inspect(type)}; expected one of #{inspect(@types)}"
  end
end
