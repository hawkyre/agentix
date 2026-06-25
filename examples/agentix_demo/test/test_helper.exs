ExUnit.start()

# No sandbox (see config/test.exs): start from a clean slate so unique-id conversations from
# a prior run can't surface stale history.
AgentixDemo.Repo.query!(
  "TRUNCATE agentix_conversations, agentix_events, agentix_summaries, " <>
    "agentix_tool_calls, agentix_model_calls, oban_jobs RESTART IDENTITY CASCADE"
)
