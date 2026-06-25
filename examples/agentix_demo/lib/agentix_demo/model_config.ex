defmodule AgentixDemo.ModelConfig do
  @moduledoc false
  # Picks the provider + model from the environment: real Claude when `ANTHROPIC_API_KEY` is
  # set, the key-free `AgentixDemo.OfflineProvider` otherwise. Pure functions so the selection
  # is unit-testable without booting the app (config/runtime.exs calls `provider/0`).

  @model "anthropic:claude-haiku-4-5"

  @doc "The model string passed to the agent config (ignored by the offline provider)."
  @spec model() :: String.t()
  def model, do: @model

  @doc "The provider module for the given API key (defaults to the live env var)."
  @spec provider(String.t() | nil) :: module()
  def provider(api_key \\ System.get_env("ANTHROPIC_API_KEY"))
  def provider(key) when key in [nil, ""], do: AgentixDemo.OfflineProvider
  def provider(_key), do: Agentix.Provider.ReqLLM

  @doc "True when no API key is configured (the demo runs on the offline provider)."
  @spec offline?(String.t() | nil) :: boolean()
  def offline?(api_key \\ System.get_env("ANTHROPIC_API_KEY")),
    do: provider(api_key) == AgentixDemo.OfflineProvider
end
