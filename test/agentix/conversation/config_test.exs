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
        "audit?" => true,
        # The nested tool_retention map round-trips through jsonb as fully string-keyed
        # (keys and the :mode value); Config.new must rebuild it without raising.
        "tool_retention" => %{"mode" => "count", "value" => 8, "never_evict" => true}
      })

    assert config.model == "openai:gpt-x"
    assert config.system_prompt == "be terse"
    assert config.working_budget == 16_000
    assert config.audit? == true
    assert config.tool_retention == %{mode: :count, value: 8, never_evict: true}
  end

  test "new/1 still raises on an unknown string key" do
    assert_raise KeyError, fn -> Config.new(%{"model" => "m", "working_buget" => 100}) end
  end

  describe "retry policy" do
    test "defaults to 3 attempts with exponential backoff bounds" do
      assert Config.new(model: "m").retry == %{max_attempts: 3, base_ms: 500, max_ms: 8_000}
    end

    test "accepts a full override map" do
      retry = %{max_attempts: 5, base_ms: 100, max_ms: 4_000}
      assert Config.new(model: "m", retry: retry).retry == retry
    end

    test "merges a partial map with the defaults" do
      assert Config.new(model: "m", retry: %{max_attempts: 7}).retry ==
               %{max_attempts: 7, base_ms: 500, max_ms: 8_000}
    end

    test "accepts false to disable" do
      assert Config.new(model: "m", retry: false).retry == false
    end

    test "rejects a zero/negative max_attempts" do
      assert_raise ArgumentError, ~r/retry must be false/, fn ->
        Config.new(model: "m", retry: %{max_attempts: 0, base_ms: 1, max_ms: 1})
      end
    end

    test "rejects max_ms below base_ms" do
      assert_raise ArgumentError, ~r/retry must be false/, fn ->
        Config.new(model: "m", retry: %{max_attempts: 3, base_ms: 1000, max_ms: 500})
      end
    end

    test "rejects a non-map, non-false value" do
      assert_raise ArgumentError, ~r/retry must be false/, fn ->
        Config.new(model: "m", retry: 3)
      end
    end

    test "an explicit nil field is rejected, not silently healed to the default" do
      assert_raise ArgumentError, ~r/retry must be false/, fn ->
        Config.new(model: "m", retry: %{max_attempts: nil, base_ms: 100, max_ms: 500})
      end
    end

    test "round-trips through a string-keyed JSON map (Ecto revival)" do
      config =
        Config.new(%{
          "model" => "m",
          "retry" => %{"max_attempts" => 5, "base_ms" => 100, "max_ms" => 4_000}
        })

      assert config.retry == %{max_attempts: 5, base_ms: 100, max_ms: 4_000}
    end
  end

  describe "response_format (default output schema)" do
    test "defaults to nil (plain text)" do
      assert Config.new(model: "m").response_format == nil
    end

    test "accepts a JSON Schema map" do
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
      assert Config.new(model: "m", response_format: schema).response_format == schema
    end

    test "accepts a NimbleOptions keyword" do
      schema = [sentiment: [type: :string], score: [type: :float]]
      assert Config.new(model: "m", response_format: schema).response_format == schema
    end

    test "rejects a non-schema scalar" do
      assert_raise ArgumentError, ~r/response_format must be/, fn ->
        Config.new(model: "m", response_format: 123)
      end
    end

    test "rejects an empty map and an empty list" do
      assert_raise ArgumentError, fn -> Config.new(model: "m", response_format: %{}) end
      assert_raise ArgumentError, fn -> Config.new(model: "m", response_format: []) end
    end

    test "rejects a non-keyword list" do
      assert_raise ArgumentError, ~r/response_format/, fn ->
        Config.new(model: "m", response_format: [1, 2, 3])
      end
    end

    test "round-trips a map through a string-keyed JSON revival" do
      schema = %{"type" => "object"}
      config = Config.new(%{"model" => "m", "response_format" => schema})
      assert config.response_format == schema
    end
  end
end
