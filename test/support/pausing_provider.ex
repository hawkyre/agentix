defmodule Agentix.Test.PausingProvider do
  @moduledoc false
  # A provider that streams one text chunk, then blocks the streaming task until the
  # test releases it — so a snapshot taken in between observes a genuinely mid-stream
  # turn (partial assistant text, `:streaming` state). Configure via
  # `config :agentix, :pausing_provider, %{text: ..., test_pid: ...}`; the test receives
  # `{:agentix_streaming, task_pid}` and resumes the stream by sending `:agentix_release`.
  @behaviour Agentix.Provider

  alias Agentix.Provider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk

  @impl Provider
  def stream(_model, _context, _opts) do
    %{text: text, test_pid: test_pid} = Application.fetch_env!(:agentix, :pausing_provider)

    chunks =
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {[StreamChunk.text(text)], :pause}

          :pause ->
            send(test_pid, {:agentix_streaming, self()})

            receive do
              :agentix_release -> :ok
            after
              5_000 -> :ok
            end

            {:halt, :done}
        end,
        fn _acc -> :ok end
      )

    message = %Message{role: :assistant, content: [ContentPart.text(text)]}

    {:ok,
     %Provider.Stream{
       chunks: chunks,
       cancel: fn -> :ok end,
       finalize: fn -> {message, %{}} end
     }}
  end
end
