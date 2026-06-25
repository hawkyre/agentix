defmodule Agentix.RetryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Agentix.Retry
  alias ReqLLM.Error.API.Request

  doctest Retry

  describe "retryable?/1" do
    test "429 and 5xx are retryable" do
      assert Retry.retryable?(Request.exception(status: 429))
      assert Retry.retryable?(Request.exception(status: 500))
      assert Retry.retryable?(Request.exception(status: 503))
      assert Retry.retryable?(Request.exception(status: 599))
    end

    test "a transport error (nil status) is retryable" do
      assert Retry.retryable?(Request.exception(status: nil, cause: :closed))
      assert Retry.retryable?(Request.exception(status: nil, cause: :timeout))
    end

    test "4xx other than 429 are terminal" do
      refute Retry.retryable?(Request.exception(status: 400))
      refute Retry.retryable?(Request.exception(status: 401))
      refute Retry.retryable?(Request.exception(status: 403))
      refute Retry.retryable?(Request.exception(status: 404))
    end

    test "non-Request reasons are terminal (fail fast on the unknown)" do
      refute Retry.retryable?(:boom)
      refute Retry.retryable?(%RuntimeError{message: "x"})
      refute Retry.retryable?({:error, :weird})
    end
  end

  describe "retry_after_ms/1" do
    test "parses delta-seconds from the retry-after header (string)" do
      assert Retry.retry_after_ms(Request.exception(headers: %{"retry-after" => "2"})) == 2_000
    end

    test "parses an integer seconds value" do
      assert Retry.retry_after_ms(Request.exception(headers: %{"retry-after" => 3})) == 3_000
    end

    test "is case-insensitive on the header name" do
      assert Retry.retry_after_ms(Request.exception(headers: %{"Retry-After" => "1"})) == 1_000
    end

    test "nil when absent, unparseable, or not a Request" do
      assert Retry.retry_after_ms(Request.exception(headers: %{})) == nil
      assert Retry.retry_after_ms(Request.exception(headers: %{"retry-after" => "soon"})) == nil
      assert Retry.retry_after_ms(:boom) == nil
    end
  end

  describe "delay/3" do
    @policy %{base_ms: 100, max_ms: 2_000}

    test "stays within the equal-jitter band [capped/2, capped] for each attempt" do
      for attempt <- 1..6 do
        capped = min(100 <<< (attempt - 1), 2_000)
        delay = Retry.delay(attempt, @policy)
        assert delay >= div(capped, 2), "attempt #{attempt}: #{delay} < #{div(capped, 2)}"
        assert delay <= capped, "attempt #{attempt}: #{delay} > #{capped}"
      end
    end

    test "is capped at max_ms for large attempts" do
      for _ <- 1..50 do
        delay = Retry.delay(20, @policy)
        assert delay >= 1_000 and delay <= 2_000
      end
    end

    test "honors retry-after when it exceeds the computed backoff" do
      assert Retry.delay(1, @policy, 5_000) >= 5_000
    end

    test "ignores retry-after when the computed backoff is already larger" do
      # attempt 6 caps at 2000; a 1ms server hint can't shrink it.
      assert Retry.delay(6, @policy, 1) <= 2_000
      assert Retry.delay(6, @policy, 1) >= 1_000
    end
  end
end
