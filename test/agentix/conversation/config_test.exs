defmodule Agentix.Conversation.ConfigTest do
  use ExUnit.Case, async: true

  alias Agentix.Conversation.Config

  test "new/1 requires a non-empty :model" do
    assert_raise ArgumentError, ~r/requires a non-empty :model/, fn -> Config.new([]) end
    assert_raise ArgumentError, ~r/requires a non-empty :model/, fn -> Config.new(model: "") end
    assert_raise ArgumentError, ~r/requires a non-empty :model/, fn -> Config.new(model: nil) end
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

  test "new/1 rejects non-positive numeric knobs" do
    assert_raise ArgumentError, ~r/working_budget must be a positive integer/, fn ->
      Config.new(model: "m", working_budget: 0)
    end

    assert_raise ArgumentError, ~r/default_timeout must be a positive integer/, fn ->
      Config.new(model: "m", default_timeout: -1)
    end
  end

  test "new/1 raises on unknown keys" do
    assert_raise KeyError, fn -> Config.new(model: "m", working_buget: 100) end
  end

  test "new/1 accepts string keys naming a known field (revival from a JSON adapter)" do
    config =
      Config.new(%{
        "model" => "openai:gpt-x",
        "system_prompt" => "be terse",
        "working_budget" => 16_000,
        "audit?" => true
      })

    assert config.model == "openai:gpt-x"
    assert config.system_prompt == "be terse"
    assert config.working_budget == 16_000
    assert config.audit? == true
  end

  test "new/1 still raises on an unknown string key" do
    assert_raise KeyError, fn -> Config.new(%{"model" => "m", "working_buget" => 100}) end
  end
end
