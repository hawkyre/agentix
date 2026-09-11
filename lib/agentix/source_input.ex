defmodule Agentix.SourceInput do
  @moduledoc """
  A stored host message to admit at an execution checkpoint.

  `source_id` identifies one message across retries. `source_sequence` orders
  messages within the conversation. `actor` records the author as JSON data;
  it does not grant tool permissions. `message` must have the user role.
  """
  @enforce_keys [:source_id, :source_sequence, :actor, :message]
  defstruct [:source_id, :source_sequence, :actor, :message]

  @type t :: %__MODULE__{
          source_id: String.t(),
          source_sequence: non_neg_integer(),
          actor: map(),
          message: ReqLLM.Message.t()
        }
end
