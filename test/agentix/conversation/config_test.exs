defmodule Agentix.Conversation.ConfigTest do
  use ExUnit.Case, async: true

  alias Agentix.Conversation.Config

  test "new/1 requires :model" do
    assert_raise ArgumentError, ~r/requires :model/, fn -> Config.new([]) end
  end

  test "new/1 applies sensible defaults" do
    config = Config.new(model: "anthropic:claude-opus-4-8")
    assert config.model == "anthropic:claude-opus-4-8"
    assert config.system_prompt == nil
    assert config.tools == []
    assert config.working_budget == 30_000
    assert config.default_timeout == 300_000
    assert config.audit? == false
    assert config.persistence == nil
  end

  test "new/1 overrides defaults from attrs" do
    config =
      Config.new(%{
        model: "openai:gpt-x",
        system_prompt: "be terse",
        working_budget: 16_000,
        audit?: true
      })

    assert config.system_prompt == "be terse"
    assert config.working_budget == 16_000
    assert config.audit? == true
  end
end
