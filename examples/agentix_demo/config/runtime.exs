import Config

# Pick the provider at boot, mirroring `AgentixDemo.ModelConfig.provider/1` (the tested rule).
# Inlined here with module atoms (not a function call) so it never depends on app code being
# loaded when runtime config is evaluated. In :test the suite installs the mock provider.
if config_env() != :test do
  provider =
    if (System.get_env("ANTHROPIC_API_KEY") || "") != "",
      do: Agentix.Provider.ReqLLM,
      else: AgentixDemo.OfflineProvider

  config :agentix, :provider, provider
end
