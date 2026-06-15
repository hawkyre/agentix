defmodule Agentix.Hook.OverflowError do
  @moduledoc """
  Raised when a pre-hook injects more content than the conversation's
  `injection_reserve` allows. Names the offending hook. A loud config error — the
  injection/compaction subsystems are independent, so this never triggers
  compaction.
  """

  defexception [:hook, :reserve, :size, :message]

  @impl true
  def exception(opts) do
    hook = Keyword.fetch!(opts, :hook)
    reserve = Keyword.fetch!(opts, :reserve)
    size = Keyword.fetch!(opts, :size)

    message =
      "hook #{inspect(hook)} injected ~#{size} tokens, exceeding the injection_reserve " <>
        "of #{reserve}; trim the injection or raise :injection_reserve (compaction is " <>
        "not re-entered to make room)"

    %__MODULE__{hook: hook, reserve: reserve, size: size, message: message}
  end
end
