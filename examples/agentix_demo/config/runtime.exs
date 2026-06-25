import Config

# Load .env *here* so the provider decision below sees ANTHROPIC_API_KEY. ReqLLM also reads
# .env, but only at application start — which is after runtime config is evaluated — so without
# this the key wouldn't be set yet and we'd wrongly fall back to the offline provider.
env_file = Path.expand("../.env", __DIR__)

if config_env() != :test and File.exists?(env_file) do
  for line <- File.stream!(env_file),
      trimmed = String.trim(line),
      trimmed != "" and not String.starts_with?(trimmed, "#"),
      [k, v] = String.split(trimmed, "=", parts: 2) do
    System.put_env(String.trim(k), String.trim(v))
  end
end

# Pick the provider, mirroring `AgentixDemo.ModelConfig.provider/1` (the tested rule). Inlined
# with module atoms (not a function call) so it never depends on app code being loaded yet. In
# :test the suite installs the mock provider.
if config_env() != :test do
  provider =
    if (System.get_env("ANTHROPIC_API_KEY") || "") != "",
      do: Agentix.Provider.ReqLLM,
      else: AgentixDemo.OfflineProvider

  config :agentix, :provider, provider
end
