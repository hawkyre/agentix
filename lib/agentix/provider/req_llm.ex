defmodule Agentix.Provider.ReqLLM do
  @moduledoc """
  The default `Agentix.Provider` — a thin wrapper over `ReqLLM.stream_text/3`, or
  `ReqLLM.stream_object/4` when the turn requests structured output.

  When `opts` carry a `:schema` (a NimbleOptions keyword or JSON Schema map), the
  adapter calls `ReqLLM.stream_object/4` instead — ReqLLM implements structured output
  as a forced `structured_output` tool call. `finalize` then extracts the parsed object
  with `ReqLLM.Response.unwrap_object/1` (from the already-collected chunks — never
  re-consuming the stream) and stashes it in the assistant message's `metadata["object"]`,
  where `Agentix.object/1` reads it.

  `ReqLLM.stream_text/3` returns `{:ok, %ReqLLM.StreamResponse{}}` (not a bare
  stream). The struct carries a lazy `stream` of `%ReqLLM.StreamChunk{}`, a
  `metadata_handle` collected concurrently, and a `cancel` closure that actually
  closes the socket. This adapter maps that onto the normalized
  `Agentix.Provider.Stream` the agent consumes:

    * `chunks` — the lazy stream, wrapped so each chunk is accumulated as the agent
      forwards it as a live delta;
    * `cancel` — `StreamResponse`'s own closure, passed through unchanged (the agent
      invokes it on `:cancel` so the HTTP connection is freed);
    * `finalize` — awaits the metadata handle and rebuilds the finalized assistant
      `%ReqLLM.Message{}` + usage from the accumulated chunks, reusing ReqLLM's own
      `ResponseBuilder` so tool-call ids (assembled by ReqLLM, absent from
      individual `StreamChunk`s) survive. Call it **after** `chunks` is consumed.

  Streaming pools are HTTP/1-only by default (Finch ALPN bug with mixed-protocol
  large bodies).
  """

  @behaviour Agentix.Provider

  alias Agentix.Provider
  alias ReqLLM.Provider.ResponseBuilder
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse.MetadataHandle

  @impl true
  def stream(model, context, opts) do
    # A `:schema` opt switches to structured-output mode (a forced tool call); ReqLLM
    # takes the schema as its positional 3rd arg, not inside `opts`.
    {schema, opts} = Keyword.pop(opts, :schema)

    result =
      if schema do
        ReqLLM.stream_object(model, context, schema, opts)
      else
        ReqLLM.stream_text(model, context, opts)
      end

    case result do
      {:ok, stream_response} -> {:ok, build_stream(stream_response, schema != nil)}
      {:error, _reason} = error -> error
    end
  end

  defp build_stream(stream_response, object?) do
    # `build_stream/1` runs inside the agent's stream-consuming task (`Agent.run_stream/6`), so
    # `start_link` links the collector to that task. The happy path stops it in `finalize/2`;
    # on cancel/error the agent terminates the task (`Task.Supervisor.terminate_child/2`), which
    # takes the linked collector down too — so it's never orphaned. Keep this caller a process
    # whose death should reap the collector, or stop it explicitly if that ever changes.
    {:ok, collector} = Agent.start_link(fn -> [] end)

    chunks =
      Stream.map(stream_response.stream, fn chunk ->
        Agent.update(collector, &[chunk | &1])
        chunk
      end)

    %Provider.Stream{
      chunks: chunks,
      cancel: stream_response.cancel,
      finalize: fn -> finalize(stream_response, collector, object?) end
    }
  end

  defp finalize(stream_response, collector, object?) do
    collected = Agent.get(collector, &Enum.reverse(&1))
    Agent.stop(collector)
    metadata = MetadataHandle.await(stream_response.metadata_handle)
    builder = ResponseBuilder.for_model(stream_response.model)

    {:ok, response} =
      builder.build_response(collected, metadata,
        context: stream_response.context,
        model: stream_response.model
      )

    {maybe_put_object(response, object?), response.usage}
  end

  # Structured-output turn: extract the parsed object from the already-built response
  # (via the forced `structured_output` tool call) and stash it in the message metadata.
  # `unwrap_object/1` reads the response/message — it does not re-consume the stream.
  defp maybe_put_object(%{message: message}, false), do: message

  defp maybe_put_object(%{message: message} = response, true) do
    case Response.unwrap_object(response) do
      {:ok, object} -> %{message | metadata: Map.put(message.metadata || %{}, "object", object)}
      {:error, _reason} -> message
    end
  end
end
