defmodule Agentix.Test do
  @moduledoc """
  Test helpers for driving agents deterministically without an API key.

  `import Agentix.Test` in your test module to get:

    * `install_mock_provider/0` — make `Agentix.Test.MockProvider` the active
      provider and start it.
    * `completion/2` — build a scripted response spec (text, tool calls, thinking,
      and an optional structured `:object`).
    * `error/2` and `transport_error/1` — build a scripted *failure* spec so the mock
      provider returns `{:error, reason}` (an HTTP status error or a connection drop),
      for exercising the retry path.
    * `assert_tool_called/2` and `assert_suspended_on/2` — assert on what the agent
      durably recorded (the canonical log and pending tool calls), not on internal
      state, so the assertions hold across a kill/resume.

  These run `async: false` (the mock provider is globally named and the audit/provider
  config is process-global).
  """

  import ExUnit.Assertions

  alias Agentix.Persistence
  alias Agentix.Test.MockProvider
  alias ReqLLM.Error.API.Request

  @doc """
  Installs the mock provider (sets `config :agentix, :provider` and starts it).
  Safe to call repeatedly — resets the script if already running.
  """
  @spec install_mock_provider() :: :ok
  def install_mock_provider do
    Application.put_env(:agentix, :provider, MockProvider)
    ensure_mock_provider()
  end

  # Start the MockProvider under ExUnit's per-test supervisor (matching
  # `Agentix.Test.MockProviderTest`), so ExUnit terminates it and frees the shared global
  # name deterministically before the next test's setup. A bare `start_link/0` linked it to
  # the transient test process instead, so under load the dying agent's name lingered and
  # the next test raced it — surfacing as `:noproc` on `script`/`reset` or leaked requests.
  defp ensure_mock_provider do
    case ExUnit.Callbacks.start_supervised(MockProvider) do
      {:ok, _pid} -> :ok
      # Already supervised in this test (install called more than once) — clear its state.
      {:error, _reason} -> MockProvider.reset()
    end
  end

  @doc """
  Builds a response spec for the mock provider.

  Options: `:tool_calls` (a list of `{name, arguments_map}`), `:thinking` (reasoning
  text), `:usage` (a usage map), `:object` (a structured-output value placed in the
  finalized message's `metadata["object"]`). Pass the result to
  `Agentix.Test.MockProvider.script/1`.
  """
  @spec completion(String.t(), keyword()) :: map()
  def completion(text, opts \\ []) when is_binary(text) do
    %{
      text: text,
      thinking: Keyword.get(opts, :thinking),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      usage: Keyword.get(opts, :usage, %{}),
      object: Keyword.get(opts, :object)
    }
  end

  @doc """
  Builds a *failure* spec: the next `stream/3` call returns `{:error, reason}` where
  `reason` is a `ReqLLM.Error.API.Request` carrying `status` (the HTTP code). Matches
  the shape ReqLLM surfaces for 4xx/5xx so `Agentix.Retry`'s classifier sees real data.

  Options: `:reason` (the message string), `:retry_after` (seconds, placed in the
  `retry-after` response header for the backoff to honor).
  """
  @spec error(pos_integer(), keyword()) :: map()
  def error(status, opts \\ []) when is_integer(status) do
    retry_after = Keyword.get(opts, :retry_after)
    # Mirror Req.Response.headers: a case-insensitive map of name => [values].
    headers = if retry_after, do: %{"retry-after" => [to_string(retry_after)]}, else: %{}

    reason =
      Request.exception(
        reason: Keyword.get(opts, :reason, "mock HTTP #{status}"),
        status: status,
        headers: headers
      )

    %{__error__: reason}
  end

  @doc """
  Builds a *failure* spec for a transport-level error (connection drop / timeout):
  `stream/3` returns `{:error, reason}` with `status: nil` and the transport `reason`
  as the cause — the shape ReqLLM produces when the socket fails before any HTTP status.
  """
  @spec transport_error(atom()) :: map()
  def transport_error(reason \\ :closed) when is_atom(reason) do
    error =
      Request.exception(
        reason: "mock transport error: #{reason}",
        status: nil,
        cause: reason
      )

    %{__error__: error}
  end

  @doc """
  Asserts the conversation's log contains a `:tool_call` event for `tool_name`.
  """
  @spec assert_tool_called(String.t(), String.t()) :: true
  def assert_tool_called(conversation_id, tool_name) do
    names =
      conversation_id
      |> Persistence.stream_events()
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(&event_name/1)

    assert tool_name in names,
           "expected a tool call to #{inspect(tool_name)} in conversation " <>
             "#{inspect(conversation_id)}, but called: #{inspect(names)}"
  end

  @doc """
  Asserts the conversation is suspended on a pending tool call named `tool_name`.
  """
  @spec assert_suspended_on(String.t(), String.t()) :: true
  def assert_suspended_on(conversation_id, tool_name) do
    pending = Persistence.pending_tool_calls(conversation_id)
    names = Enum.map(pending, &tool_call_name/1)

    assert tool_name in names,
           "expected conversation #{inspect(conversation_id)} to be suspended on " <>
             "#{inspect(tool_name)}, but pending: #{inspect(names)}"
  end

  defp event_name(%{content: content}), do: content[:name] || content["name"]
  defp tool_call_name(tool_call), do: tool_call[:name] || tool_call["name"]
end
