defmodule Agentix.Test.MockProvider do
  @moduledoc """
  A scriptable `Agentix.Provider` for deterministic tests — no API key, no network.

  Enqueue response specs with `script/1`; each `stream/3` call pops the next one
  (FIFO) and records the request. Build specs with `Agentix.Test.completion/2`.

  Process-based and globally named, so drive it from a single test process and run
  those tests `async: false`. Start it with `start_supervised!(Agentix.Test.MockProvider)`
  (or `Agentix.Test.install_mock_provider/0`).
  """

  @behaviour Agentix.Provider

  use Agent

  alias Agentix.Provider
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{scripts: :queue.new(), requests: []} end, name: __MODULE__)
  end

  @doc """
  Enqueue one response spec (a map from `Agentix.Test.completion/2`) or a list of
  them, consumed FIFO by `stream/3`.
  """
  @spec script(map() | [map()]) :: :ok
  def script(spec) when is_map(spec), do: script([spec])

  def script(specs) when is_list(specs) do
    Agent.update(__MODULE__, fn state ->
      %{state | scripts: Enum.reduce(specs, state.scripts, &:queue.in/2)}
    end)
  end

  @doc "The requests received so far, oldest first."
  @spec requests() :: [map()]
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @doc "Clear scripts and recorded requests."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{scripts: :queue.new(), requests: []} end)

  @impl Provider
  def stream(model, context, opts) do
    spec =
      Agent.get_and_update(__MODULE__, fn state ->
        {spec, scripts} =
          case :queue.out(state.scripts) do
            {{:value, spec}, rest} -> {spec, rest}
            {:empty, queue} -> {%{}, queue}
          end

        request = %{model: model, context: context, opts: opts}
        {spec, %{state | scripts: scripts, requests: [request | state.requests]}}
      end)

    {:ok, build_stream(spec)}
  end

  defp build_stream(spec) do
    spec = normalize(spec)
    message = message_for(spec)
    usage = spec.usage

    %Provider.Stream{
      chunks: chunks_for(spec),
      cancel: fn -> :ok end,
      finalize: fn -> {message, usage} end
    }
  end

  defp normalize(spec) do
    spec = Map.new(spec)

    %{
      text: Map.get(spec, :text, ""),
      thinking: Map.get(spec, :thinking),
      tool_calls: spec |> Map.get(:tool_calls, []) |> Enum.map(&normalize_tool_call/1),
      usage: Map.get(spec, :usage, %{})
    }
  end

  defp normalize_tool_call({name, arguments}), do: %{name: name, arguments: arguments}

  defp normalize_tool_call(%{name: name} = tc),
    do: %{name: name, arguments: Map.get(tc, :arguments, %{})}

  defp chunks_for(spec) do
    thinking = if spec.thinking, do: [StreamChunk.thinking(spec.thinking)], else: []
    text = if spec.text == "", do: [], else: [StreamChunk.text(spec.text)]
    tools = Enum.map(spec.tool_calls, &StreamChunk.tool_call(&1.name, &1.arguments))
    thinking ++ text ++ tools
  end

  defp message_for(spec) do
    content = if spec.text == "", do: [], else: [ContentPart.text(spec.text)]

    tool_calls =
      case Enum.map(spec.tool_calls, &ToolCall.new(nil, &1.name, Jason.encode!(&1.arguments))) do
        [] -> nil
        list -> list
      end

    %Message{role: :assistant, content: content, tool_calls: tool_calls}
  end
end
