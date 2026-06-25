defmodule Agentix.Retry do
  @moduledoc """
  Transient-failure classification and backoff for the **pre-stream** provider call.

  When `Agentix.Provider.stream/3` returns `{:error, reason}` *before* any token has
  streamed, the agent retries it according to the conversation's `retry` policy (see
  `Agentix.Conversation.Config`). This module is the policy's two pure pieces:

    * `retryable?/1` — is this error transient (worth retrying) or terminal?
    * `delay/3` — how long to back off before the next attempt.

  A failure that happens *after* streaming has begun is never retried (re-issuing the
  request would duplicate already-emitted output); that path crashes the streaming task
  and fails the turn, and never reaches this module.

  ## What counts as retryable

  Errors surface as `ReqLLM.Error.API.Request` (ReqLLM normalizes every HTTP and
  transport failure to this struct). The classification mirrors which failures are
  genuinely transient:

    * HTTP **429** (rate limited) and **5xx** (server/overload) → retryable.
    * A **transport** error (`status: nil` — connection drop/timeout before any HTTP
      status) → retryable.
    * HTTP **4xx** other than 429 (auth, bad request, not found) → terminal.
    * Anything else → terminal (fail fast rather than hammer on an unknown error).

  Classification matches `ReqLLM.Error.API.Request` (ReqLLM is the canonical provider
  model the library is built on). An error of any other shape — e.g. from a custom
  `Agentix.Provider` returning a bespoke reason — is treated as **terminal** (not
  retried). A future `Agentix.Provider.Error` normalization could make retry
  provider-agnostic; until then, fail-fast on the unknown is the safe default.
  """

  import Bitwise

  alias ReqLLM.Error.API.Request

  # Absolute ceiling on a single backoff, in milliseconds. Bounds a server-supplied
  # `retry-after` so a hostile/buggy provider cannot pin the streaming task asleep.
  @max_delay_ms 60_000

  @doc """
  Classifies a provider error `reason` as transient (`true`) or terminal (`false`).

      iex> Agentix.Retry.retryable?(ReqLLM.Error.API.Request.exception(status: 503))
      true
      iex> Agentix.Retry.retryable?(ReqLLM.Error.API.Request.exception(status: 401))
      false
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%Request{status: status}) when is_integer(status),
    do: status == 429 or status >= 500

  # No HTTP status means the socket failed before a response — a transport blip.
  def retryable?(%Request{status: nil}), do: true
  def retryable?(_other), do: false

  @doc """
  Extracts a server-requested backoff from a `retry-after` response header, in
  milliseconds, or `nil` when absent/unparseable. Accepts the delta-seconds form
  (a count of seconds); the HTTP-date form is ignored (returns `nil`).

  Header shapes vary by provider path: `ReqLLM` carries `Req.Response` headers as a
  case-insensitive map of `name => [values]`, but other paths use a list of
  `{name, value}` tuples. Both are handled, the lookup is case-insensitive, and a
  multi-value header takes its first value.
  """
  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(%Request{headers: headers}) do
    headers |> header_value("retry-after") |> parse_seconds()
  end

  def retry_after_ms(_other), do: nil

  defp header_value(headers, name) when is_map(headers) or is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if downcase(key) == name, do: first_value(value)
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp downcase(key) when is_binary(key), do: String.downcase(key)
  defp downcase(key), do: key

  defp first_value([value | _]), do: value
  defp first_value(value), do: value

  @doc """
  Backoff before the next attempt, in milliseconds, for a 1-based `attempt` number.

  Exponential `base_ms * 2^(attempt-1)` capped at `max_ms`, then "equal jitter" (half
  fixed, half random) so retrying clients de-synchronize. When the server asked for a
  longer wait via `retry-after`, that wins — but the whole result is capped at
  `#{@max_delay_ms} ms` so a hostile or buggy server's `retry-after` can't pin the
  streaming task in `Process.sleep` for an unbounded time.

  The result is always `≤ #{@max_delay_ms}` and (below that ceiling) `≥ retry_after_ms`.
  """
  @spec delay(
          pos_integer(),
          %{base_ms: pos_integer(), max_ms: pos_integer()},
          non_neg_integer() | nil
        ) ::
          non_neg_integer()
  def delay(attempt, policy, retry_after_ms \\ nil)

  def delay(attempt, %{base_ms: base, max_ms: max}, retry_after_ms) when attempt >= 1 do
    # Cap the shift so a large `max_attempts` can't allocate an enormous bignum before
    # `min/2` clamps it (2^30 ms ≈ 12 days, already far above any sane `max_ms`).
    capped = min(base <<< min(attempt - 1, 30), max)
    half = div(capped, 2)
    jittered = half + random_int(half)
    jittered |> Kernel.max(retry_after_ms || 0) |> min(@max_delay_ms)
  end

  # Reject trailing garbage: "30abc" must not be read as 30 seconds.
  defp parse_seconds(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _ -> nil
    end
  end

  defp parse_seconds(seconds) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  defp parse_seconds(_other), do: nil

  # Uniform integer in 0..n (inclusive); safe for n == 0.
  defp random_int(0), do: 0
  defp random_int(n) when n > 0, do: :rand.uniform(n + 1) - 1
end
