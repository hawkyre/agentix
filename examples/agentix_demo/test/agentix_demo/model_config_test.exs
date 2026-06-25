defmodule AgentixDemo.ModelConfigTest do
  use ExUnit.Case, async: true

  alias AgentixDemo.ModelConfig

  test "no API key selects the key-free offline provider" do
    assert ModelConfig.provider(nil) == AgentixDemo.OfflineProvider
    assert ModelConfig.provider("") == AgentixDemo.OfflineProvider
    assert ModelConfig.offline?(nil)
  end

  test "a present API key selects the real ReqLLM provider" do
    assert ModelConfig.provider("sk-ant-xxx") == Agentix.Provider.ReqLLM
    refute ModelConfig.offline?("sk-ant-xxx")
  end
end
