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
  """

  import Bitwise

  alias ReqLLM.Error.API.Request

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
  (a string or integer count of seconds); the HTTP-date form is ignored (returns `nil`).
  """
  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(%Request{headers: headers}) when is_map(headers) do
    case headers["retry-after"] || headers["Retry-After"] do
      nil -> nil
      value -> parse_seconds(value)
    end
  end

  def retry_after_ms(_other), do: nil

  @doc """
  Backoff before the next attempt, in milliseconds, for a 1-based `attempt` number.

  Exponential `base_ms * 2^(attempt-1)` capped at `max_ms`, then "equal jitter" (half
  fixed, half random) so retrying clients de-synchronize. When the server asked for a
  longer wait via `retry-after`, that wins.

  The result is always `≤ max(max_ms, retry_after_ms)` and `≥ retry_after_ms`.
  """
  @spec delay(
          pos_integer(),
          %{base_ms: pos_integer(), max_ms: pos_integer()},
          non_neg_integer() | nil
        ) ::
          non_neg_integer()
  def delay(attempt, policy, retry_after_ms \\ nil)

  def delay(attempt, %{base_ms: base, max_ms: max}, retry_after_ms) when attempt >= 1 do
    capped = min(base <<< (attempt - 1), max)
    half = div(capped, 2)
    jittered = half + random_int(half)
    Kernel.max(jittered, retry_after_ms || 0)
  end

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _rest} when seconds >= 0 -> seconds * 1000
      _ -> nil
    end
  end

  defp parse_seconds(seconds) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  defp parse_seconds(_other), do: nil

  # Uniform integer in 0..n (inclusive); safe for n == 0.
  defp random_int(0), do: 0
  defp random_int(n) when n > 0, do: :rand.uniform(n + 1) - 1
end
