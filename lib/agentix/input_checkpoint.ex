defmodule Agentix.InputCheckpoint do
  @moduledoc """
  Durable admission state passed to the host input source.

  The source returns `{:ok, inputs}` in source sequence order, or `{:error, reason}`.
  Use `admitted_source_ids` to exclude delivered messages. `last_source_sequence`
  permits incremental reads when the host assigns sequences in commit order.
  The callback runs before context assembly and before normal completion.
  It must return promptly and must not call the running agent synchronously.

  The host must return only messages authorized for this conversation. Exclude
  the message already passed to `send_message/4`. Source IDs must remain stable,
  and new source sequences must strictly increase across the retained log.
  Actor data records authorship; the callback cannot change the tool scope.
  Return errors that are safe to publish to conversation subscribers.

  Receipts remain outside model messages. Each receipt contains string keys
  `source_id`, `source_sequence`, `actor`, and `event_sequence`. History returns
  receipts from its page; snapshots return all retained receipts. The live
  `{:input_admitted, turn_ref, receipt}` event follows the successful durable write.
  Reconnect consumers must read receipts because a crash can lose a live event.
  """
  @enforce_keys [:conversation_id, :admitted_source_ids, :last_source_sequence]
  defstruct [:conversation_id, :admitted_source_ids, :last_source_sequence]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          admitted_source_ids: MapSet.t(String.t()),
          last_source_sequence: non_neg_integer() | nil
        }
  @type source :: (t() -> {:ok, [Agentix.SourceInput.t()]} | {:error, term()})
end
