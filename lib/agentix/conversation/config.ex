defmodule Agentix.Conversation.Config do
  @moduledoc """
  Per-conversation configuration: which model, the system prompt, the (v0 fixed)
  tool list, and runtime knobs.

  The runtime knobs mirror the install/config contract:

    * `working_budget` — token budget for the assembled context (`.docs/07`).
    * `default_timeout` — suspension expiry default, in milliseconds (`.docs/03`).
    * `audit?` — record `model_calls` for replay/evals (off by default, `.docs/04`).
    * `persistence` / `notifier` / `pubsub` — wiring resolved at runtime; `nil`
      falls back to the application-level configuration.
  """

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t() | nil,
          tools: list(),
          working_budget: pos_integer(),
          default_timeout: pos_integer(),
          audit?: boolean(),
          persistence: module() | {module(), keyword()} | nil,
          notifier: module() | nil,
          pubsub: atom() | nil
        }

  @enforce_keys [:model]
  defstruct [
    :model,
    system_prompt: nil,
    tools: [],
    working_budget: 30_000,
    default_timeout: 300_000,
    audit?: false,
    persistence: nil,
    notifier: nil,
    pubsub: nil
  ]

  @doc """
  Builds a config from `attrs`. Requires `:model`; raises `ArgumentError` if it is
  missing.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)

    model =
      Map.get(attrs, :model) || raise ArgumentError, "Agentix.Conversation.Config requires :model"

    %__MODULE__{
      model: model,
      system_prompt: Map.get(attrs, :system_prompt),
      tools: Map.get(attrs, :tools, []),
      working_budget: Map.get(attrs, :working_budget, 30_000),
      default_timeout: Map.get(attrs, :default_timeout, 300_000),
      audit?: Map.get(attrs, :audit?, false),
      persistence: Map.get(attrs, :persistence),
      notifier: Map.get(attrs, :notifier),
      pubsub: Map.get(attrs, :pubsub)
    }
  end
end
