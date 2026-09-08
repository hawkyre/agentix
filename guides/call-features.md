# Model-call features

Use a feature label for the business operation that makes a provider call.
The conversation label can group calls, but it does not have to describe every
operation in that conversation.

```elixir
config = Agentix.Conversation.Config.new(
  model: "your-provider:your-model",
  feature: "chat",
  summary_feature: "workspace_summary",
  model_call_log: :records
)

Agentix.Conversation.send_message(id, message, scope,
  config: config,
  feature: "view_generation"
)
```

The precedence is:

1. `Config.feature` is the conversation label and call default.
2. `send_message/4` can set `feature:` for that turn.
3. A sequential pre-hook can call `Hook.put_feature/2` for one model call.

Use explicit operation context in the hook. Do not guess a purpose from model
output or change a conversation's config during a running call.

```elixir
Agentix.Hook.pre(:call_purpose, fn turn ->
  feature = MyApp.Operations.feature_for_call(turn)
  {:cont, Agentix.Hook.put_feature(turn, feature)}
end)
```

The hook runs before each new call in a tool loop. Each call starts from the
turn default. A prior hook override does not leak into the next call or turn.
Parallel hooks only add context. Post-hooks cannot relabel a completed call.

Agentix saves the selected purpose before dispatch. Provider retries and
cancellation retain it. Recovery preserves the turn default and last call
selection. Hooks still run for context and authorization during recovery, but
cannot relabel a call whose feature was saved before dispatch. The next new
logical call can select a new feature.

Background summary calls use `Config.summary_feature`, which defaults to
`"conversation_summary"`. They do not inherit the foreground call label.

Feature values are nonblank strings of 1–255 bytes. A turn or hook can explicitly use
`nil` to omit attribution. Summary features must not be nil. Invalid turn
values raise before dispatch; invalid hook values halt the turn before dispatch.

The effective feature is stored in the existing `agentix_model_calls.feature`
column and included in foreground model-call telemetry. No migration or host
attempt table is needed. Model-call records require `model_call_log: :records`
or `:full`.
