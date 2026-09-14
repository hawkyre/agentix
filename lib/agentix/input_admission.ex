defmodule Agentix.InputAdmission do
  @moduledoc false

  alias Agentix.Codec
  alias Agentix.Event
  alias Agentix.InputCheckpoint
  alias Agentix.Persistence
  alias Agentix.SourceInput

  @spec receipts([Event.t()]) :: [map()]
  def receipts(events) do
    Enum.flat_map(events, fn
      %Event{type: :user_msg, content: %{"input_receipt" => receipt}, seq: seq} ->
        [Map.put(receipt, "event_sequence", seq)]

      _event ->
        []
    end)
  end

  @spec restore(String.t()) :: [map()]
  def restore(conversation_id), do: receipts(Persistence.stream_events(conversation_id))

  @spec refresh(String.t()) :: {:ok, [map()]} | {:error, term()}
  def refresh(conversation_id) do
    {:ok, restore(conversation_id)}
  rescue
    _error -> {:error, {:input_source, :persistence_failed}}
  catch
    _kind, _reason -> {:error, {:input_source, :persistence_failed}}
  end

  @spec checkpoint(String.t(), [map()]) :: InputCheckpoint.t()
  def checkpoint(conversation_id, receipts) do
    %InputCheckpoint{
      conversation_id: conversation_id,
      admitted_source_ids: MapSet.new(receipts, & &1["source_id"]),
      last_source_sequence: receipts |> Enum.map(& &1["source_sequence"]) |> Enum.max(fn -> nil end)
    }
  end

  @spec fetch(InputCheckpoint.source(), InputCheckpoint.t()) ::
          {:ok, [SourceInput.t()]} | {:error, term()}
  def fetch(source, checkpoint) do
    case source.(checkpoint) do
      {:ok, inputs} when is_list(inputs) -> validate(inputs, checkpoint)
      {:error, reason} -> {:error, {:input_source, reason}}
      _other -> {:error, {:input_source, :invalid_return}}
    end
  rescue
    _error -> {:error, {:input_source, :exception}}
  catch
    _kind, _reason -> {:error, {:input_source, :exception}}
  end

  @spec record(InputCheckpoint.t(), map()) :: InputCheckpoint.t()
  def record(checkpoint, receipt) do
    %{
      checkpoint
      | admitted_source_ids: MapSet.put(checkpoint.admitted_source_ids, receipt["source_id"]),
        last_source_sequence: receipt["source_sequence"]
    }
  end

  @spec append(String.t(), SourceInput.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def append(conversation_id, input, feature) do
    receipt = %{
      "source_id" => input.source_id,
      "source_sequence" => input.source_sequence,
      "actor" => input.actor |> Codec.encode!() |> Jason.decode!()
    }

    content = %{
      "message" => input.message |> Codec.encode!() |> Jason.decode!(),
      "feature" => feature,
      "input_receipt" => receipt
    }

    case Persistence.append_event(conversation_id, Event.new(:user_msg, content)) do
      {:ok, seq} -> {:ok, Map.put(receipt, "event_sequence", seq)}
      {:error, _reason} -> {:error, {:input_source, :persistence_failed}}
    end
  rescue
    _error -> {:error, {:input_source, :persistence_failed}}
  catch
    _kind, _reason -> {:error, {:input_source, :persistence_failed}}
  end

  @spec validate([term()], InputCheckpoint.t()) :: {:ok, [SourceInput.t()]} | {:error, term()}
  defp validate(inputs, checkpoint) do
    if Enum.all?(inputs, &valid?/1) and consistent_ids?(inputs) do
      fresh =
        inputs
        |> Enum.reject(&MapSet.member?(checkpoint.admitted_source_ids, &1.source_id))
        |> Enum.uniq_by(& &1.source_id)

      sequences = Enum.map(fresh, & &1.source_sequence)

      if sequences == Enum.sort(Enum.uniq(sequences)) and
           Enum.all?(
             sequences,
             &(is_nil(checkpoint.last_source_sequence) or &1 > checkpoint.last_source_sequence)
           ) do
        {:ok, fresh}
      else
        {:error, {:input_source, :invalid_sequence}}
      end
    else
      {:error, {:input_source, :invalid_input}}
    end
  end

  @spec valid?(term()) :: boolean()
  defp valid?(%SourceInput{
         source_id: id,
         source_sequence: sequence,
         actor: actor,
         message: %ReqLLM.Message{role: :user, tool_call_id: nil, tool_calls: calls} = message
       })
       when is_binary(id) and byte_size(id) > 0 and is_integer(sequence) and sequence >= 0 and
              is_map(actor) and calls in [nil, []] do
    match?(%{}, actor |> Codec.encode!() |> Jason.decode!()) and
      match?({:ok, _}, Jason.encode(message))
  end

  defp valid?(_input), do: false

  @spec consistent_ids?([SourceInput.t()]) :: boolean()
  defp consistent_ids?(inputs) do
    inputs
    |> Enum.group_by(& &1.source_id)
    |> Enum.all?(fn {_id, copies} -> length(Enum.uniq(copies)) == 1 end)
  end
end
