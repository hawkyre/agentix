defmodule Agentix.Provider.ReqLLM do
  @moduledoc """
  The default `Agentix.Provider` — a thin wrapper over `ReqLLM.stream_text/3`.

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
  large bodies); do not chase HTTP/2 streaming concurrency in v0.
  """

  @behaviour Agentix.Provider

  alias Agentix.Provider
  alias ReqLLM.Provider.ResponseBuilder
  alias ReqLLM.StreamResponse.MetadataHandle

  @impl true
  def stream(model, context, opts) do
    case ReqLLM.stream_text(model, context, opts) do
      {:ok, stream_response} -> {:ok, build_stream(stream_response)}
      {:error, _reason} = error -> error
    end
  end

  defp build_stream(stream_response) do
    {:ok, collector} = Agent.start_link(fn -> [] end)

    chunks =
      Stream.map(stream_response.stream, fn chunk ->
        Agent.update(collector, &[chunk | &1])
        chunk
      end)

    %Provider.Stream{
      chunks: chunks,
      cancel: stream_response.cancel,
      finalize: fn -> finalize(stream_response, collector) end
    }
  end

  defp finalize(stream_response, collector) do
    collected = Agent.get(collector, &Enum.reverse(&1))
    Agent.stop(collector)
    metadata = MetadataHandle.await(stream_response.metadata_handle)
    builder = ResponseBuilder.for_model(stream_response.model)

    {:ok, response} =
      builder.build_response(collected, metadata,
        context: stream_response.context,
        model: stream_response.model
      )

    {response.message, response.usage}
  end
end
