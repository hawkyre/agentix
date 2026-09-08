# Telemetry

Agentix emits [`:telemetry`](https://hexdocs.pm/telemetry) events for every turn,
every model call, and every tool call. They fire **always** — independent of
`Config.model_call_log`, which controls the durable `model_calls` rows. This is
the surface LLM observability backends (PostHog LLM analytics, Langfuse, OpenTelemetry
bridges) consume.

Events and rows answer different questions, and a cancelled turn is where they
diverge: killing the streaming task means that attempt's span emits no terminal
event at all, so a handler counting spend from telemetry silently misses it. The
durable row is written by the agent, which knows about the cancel. Use telemetry
to export live signals; use `model_call_log: :records` when the number has to be
right afterwards.

Two rules before attaching anything:

> #### Handlers run synchronously {: .warning}
>
> `:telemetry` invokes handlers in the emitting process — for `:model_call` events
> that is the streaming task on the turn's critical path. A handler that does I/O
> (an HTTP export, a slow log sink) delays the turn. Extract what you need from the
> payload, then hand delivery to your own process (see the PostHog example below).

> #### Payloads carry prompt content {: .warning}
>
> `:model_call` metadata includes the full rendered context and the assembled
> response; `:tool` metadata includes raw tool arguments. Redact or drop anything
> you do not want to leave the box before exporting to a third party. Agentix
> deliberately never puts the caller's `Agentix.Scope` on a telemetry event — its
> `current_user`/`assigns` routinely hold PII and tool-auth credentials — only the
> derived `system_call?` boolean.

## Turn events

| event | measurements | metadata |
| ----- | ------------ | -------- |
| `[:agentix, :turn, :start]` | `system_time` | `conversation_id`, `turn_ref` |
| `[:agentix, :turn, :stop]` | — | `conversation_id`, `turn_ref` |
| `[:agentix, :turn, :halt]` | — | `conversation_id`, `turn_ref`, `reason` (a hook halted the turn) |
| `[:agentix, :turn, :exception]` | — | `conversation_id`, `turn_ref`, `reason` (stream failure or cancel) |
| `[:agentix, :turn, :retry]` | `attempt`, `delay_ms` | `conversation_id`, `turn_ref`, `reason` |

`turn_ref` is the turn's opaque reference (an Erlang ref) — stable across all events
of one turn, including every model call of a tool loop.

## Model call events

One span per provider **attempt**, emitted via `:telemetry.span/3` from the
streaming task. A retried open produces a fresh span with `attempt` incremented,
alongside the existing `[:agentix, :turn, :retry]` event.

Shared metadata on all three events: `conversation_id`, `turn_ref`, `attempt`
(1-based), `model`, `context` (the rendered `ReqLLM.Context` actually sent),
`system_call?`, and `tenant_key` (nil when the conversation has none).

| event | measurements | metadata adds |
| ----- | ------------ | ------------- |
| `[:agentix, :model_call, :start]` | `system_time`, `monotonic_time` | — |
| `[:agentix, :model_call, :stop]` | `duration` (native), `monotonic_time`, `latency_ms`, `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens` | `response` (the assembled assistant `ReqLLM.Message`), `finish_reason`, `usage` (raw provider usage map) |
| `[:agentix, :model_call, :exception]` | `duration`, `monotonic_time` | `kind`, `reason`, `stacktrace` |

Notes:

  * Token measurements are mapped defensively from the provider's usage map
    (atom or string keys) and are `nil` whenever the provider does not report
    them — the raw map still rides in metadata as `usage`.
  * `finish_reason` is derived from the assembled message — `:tool_calls` when it
    carries tool calls, else `:stop`. The provider seam does not surface native
    finish reasons (`:length`, `:content_filter`, …).
  * On `:exception`, `reason` is `Agentix.Telemetry.StreamOpenError` when the
    stream failed to open (the original provider error is in its `reason` field —
    these are the attempts the retry policy may re-issue), or the raised exception
    itself for a mid-stream crash. A provider error struct typically carries the
    request body it failed on, so `reason` is prompt-bearing too: redact it
    wherever you redact `context` (it carries no API key — providers report
    response headers only).
  * A turn cancelled mid-stream kills the streaming task, so that attempt's span
    gets **no terminal event** — the turn-level terminal is the
    `{:cancelled, turn_ref}` live event.

## Tool events

One span per `tool_call_id`, from dispatch (or suspension) to its terminal. For
suspended executors (`:human`, `:client`, and gated calls) `:start` fires at
suspension and `:stop` at resolution, so `latency_ms` measures across the wait.
An approval-gated call is a single span covering approval plus execution.

Shared metadata: `conversation_id`, `turn_ref`, `tool_call_id`, `name`, `executor`
(`:server | :human | :client | :provider`, `nil` for a tool the model hallucinated),
`args`, and `tenant_key` (nil when the conversation has none).

| event | measurements | metadata adds |
| ----- | ------------ | ------------- |
| `[:agentix, :tool, :start]` | `system_time`, `monotonic_time` | — |
| `[:agentix, :tool, :stop]` | `duration` (native), `latency_ms`, `monotonic_time` | `result` (`%{ok: …}` convention), `status` (`:ok` \| `:error`) |
| `[:agentix, :tool, :exception]` | `duration`, `monotonic_time` | `kind` (`:exit`), `reason`, `stacktrace` |

Every terminal closes the span: a denial, a timeout, a turn cancel, unparseable
arguments, and an unknown tool all emit `:stop` with `status: :error`;
`:exception` fires only when a `:server` tool's task dies abnormally (a raise
inside the callback is rescued into an error result — that is a `:stop`).

Across an agent crash the original `:start`'s clock and turn are unrecoverable, so
revival closes the books approximately:

  * A **suspended** call re-opens its span on revival (a second `:start`), and its
    eventual `latency_ms` measures from revival, not from the original suspension.
  * A call that was **in flight or already resolved durably** when the agent died is
    reconciled on revival: the span closes with a `:stop` carrying `duration: 0` and
    `turn_ref: nil`, since neither is knowable after the crash. Treat a zero-duration
    tool span as "closed by recovery", not as a real measurement.

## Worked example: PostHog LLM analytics

Maps `:model_call` `:stop` to a [`$ai_generation`](https://posthog.com/docs/ai-engineering)
event and `:tool` `:stop` to `$ai_span`. Delivery is fire-and-forget on a `Task` so
the handler never blocks the turn; `distinct_id` comes from your own
conversation-to-user mapping (Agentix does not broadcast the caller's scope).

    defmodule MyApp.LLMAnalytics do
      def attach do
        :telemetry.attach_many(
          "posthog-llm",
          [[:agentix, :model_call, :stop], [:agentix, :tool, :stop]],
          &__MODULE__.handle_event/4,
          nil
        )
      end

      def handle_event([:agentix, :model_call, :stop], measurements, metadata, _config) do
        # Extract in-process (cheap), deliver off-process (the HTTP call).
        # PostHog wants the provider and bare model id separately; Agentix's model
        # is a "provider:model-id" spec string. And $ai_trace_id allows only
        # letters/numbers and - _ ~ . @ ( ) ! ' : | — phash2 keeps the turn ref legal.
        [provider, model] = String.split(metadata.model, ":", parts: 2)

        event = %{
          event: "$ai_generation",
          distinct_id: MyApp.Accounts.user_for_conversation(metadata.conversation_id),
          properties: %{
            "$ai_trace_id": "#{metadata.conversation_id}:#{:erlang.phash2(metadata.turn_ref)}",
            "$ai_provider": provider,
            "$ai_model": model,
            "$ai_input_tokens": measurements.input_tokens,
            "$ai_output_tokens": measurements.output_tokens,
            "$ai_latency": measurements.latency_ms / 1000,
            # Full prompt/response content — REDACT or drop these two if your
            # PostHog project must not hold conversation content. PostHog expects
            # native arrays of %{role, content}, not JSON strings.
            "$ai_input": Enum.map(metadata.context.messages, &message_property/1),
            "$ai_output_choices": [message_property(metadata.response)],
            tenant_key: metadata[:tenant_key]
          }
        }

        Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> MyApp.PostHog.capture(event) end)
        :ok
      end

      def handle_event([:agentix, :tool, :stop], measurements, metadata, _config) do
        event = %{
          event: "$ai_span",
          distinct_id: MyApp.Accounts.user_for_conversation(metadata.conversation_id),
          properties: %{
            "$ai_trace_id": "#{metadata.conversation_id}:#{:erlang.phash2(metadata.turn_ref)}",
            "$ai_span_name": metadata.name,
            "$ai_latency": measurements.latency_ms / 1000,
            status: metadata.status,
            executor: metadata.executor,
            tenant_key: metadata[:tenant_key]
          }
        }

        Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> MyApp.PostHog.capture(event) end)
        :ok
      end

      # A ReqLLM message's content is a list of parts; keep the text ones and drop
      # the rest (images, files) rather than shipping binaries to analytics.
      defp message_property(%ReqLLM.Message{role: role, content: content}) do
        text = content |> Enum.filter(&(&1.type == :text)) |> Enum.map_join(& &1.text)
        %{role: to_string(role), content: text}
      end
    end

A handler that raises is detached by `:telemetry` itself (with a logged warning) —
the conversation is never affected.
