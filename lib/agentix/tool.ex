defmodule Agentix.Tool do
  @moduledoc """
  A tool definition: its schema, who executes it, and how it is gated.

  Two orthogonal axes (D4, inc-6-notes):

    * **executor** — who produces the result: `:server` (your code, dispatched in a
      monitored task), `:human` (elicitation — the answer *is* the result),
      `:client` (browser/socket execution), `:provider` (provider-hosted, resolves
      in-stream — never dispatched locally).
    * **approval** — `:auto` or `:requires_approval` (a two-phase gate). Legal **only**
      on `:server` and `:client`; gating `:human` is circular and `:provider` has no
      pre-exec suspend point, so both raise at definition time.

  `streaming?` is a property (a tool emitting progress during its own execution),
  orthogonal to the executor. `retention` controls compaction eviction (Inc 8).

  ## Schema pass-through (D5)

  `parameter_schema` is handed **verbatim** to `ReqLLM.Tool.new/1` (it already
  compiles NimbleOptions / JSON-Schema). Agentix never re-compiles or re-validates
  it. The `%ReqLLM.Tool{}` produced for the provider carries a never-invoked **stub
  callback** (`__provider_stub__/1`) — Agentix drives dispatch itself and never lets
  ReqLLM auto-execute a tool. `%ReqLLM.Tool{}` is never persisted (its `compiled`
  field is not JSON-serializable); tools are rebuilt from config on revival.
  """

  @type executor :: :server | :human | :client | :provider
  @type approval :: :auto | :requires_approval

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameter_schema: keyword() | map(),
          executor: executor(),
          approval: approval(),
          streaming?: boolean(),
          retention: map() | nil,
          callback: (map(), Agentix.Turn.t() -> {:ok, term()} | {:error, term()}) | nil
        }

  @enforce_keys [:name, :executor]
  defstruct [
    :name,
    :callback,
    :retention,
    description: "",
    parameter_schema: [],
    executor: :server,
    approval: :auto,
    streaming?: false
  ]

  @executors [:server, :human, :client, :provider]
  @approvals [:auto, :requires_approval]

  @doc """
  Builds a tool from `attrs`. Raises `ArgumentError` on: an unknown key, an invalid
  `executor`/`approval`, a gated `:human`/`:provider` (illegal matrix), or a
  `:server` tool without a `callback`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    tool = struct!(__MODULE__, attrs)
    validate_executor!(tool.executor)
    validate_approval!(tool.approval)
    validate_gate_matrix!(tool.executor, tool.approval)
    validate_callback!(tool.executor, tool.callback)
    tool
  end

  @doc """
  The renderer `kind` for the call's *current* pending phase: `:approval` when gated
  (the first suspension), else `:elicitation` for `:human` / `:client_exec` for
  `:client`.
  """
  @spec pending_kind(t(), :approval | :exec) :: :approval | :elicitation | :client_exec
  def pending_kind(%__MODULE__{approval: :requires_approval}, :approval), do: :approval
  def pending_kind(%__MODULE__{executor: :human}, _phase), do: :elicitation
  def pending_kind(%__MODULE__{executor: :client}, _phase), do: :client_exec

  @doc """
  Builds the `%ReqLLM.Tool{}` list to hand the provider for schema/serialization.
  Each carries the never-invoked `__provider_stub__/1` callback; the loop owns
  dispatch. `:provider` tools are included so the model can call them.
  """
  @spec to_reqllm([t()]) :: [ReqLLM.Tool.t()]
  def to_reqllm(tools) do
    Enum.map(tools, fn %__MODULE__{} = tool ->
      ReqLLM.Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.parameter_schema,
        callback: {__MODULE__, :__provider_stub__, []}
      )
    end)
  end

  @doc false
  # Satisfies `ReqLLM.Tool.new/1`'s callback requirement; never invoked because the
  # agent loop dispatches every executor itself. Always raises by design.
  @dialyzer {:nowarn_function, __provider_stub__: 1}
  def __provider_stub__(_args) do
    raise "Agentix tools are dispatched by the agent loop, not ReqLLM"
  end

  defp validate_executor!(executor) when executor in @executors, do: :ok

  defp validate_executor!(other) do
    raise ArgumentError,
          "invalid executor #{inspect(other)}; expected one of #{inspect(@executors)}"
  end

  defp validate_approval!(approval) when approval in @approvals, do: :ok

  defp validate_approval!(other) do
    raise ArgumentError,
          "invalid approval #{inspect(other)}; expected one of #{inspect(@approvals)}"
  end

  defp validate_gate_matrix!(executor, :requires_approval) when executor in [:human, :provider] do
    raise ArgumentError,
          ":requires_approval is illegal for executor #{inspect(executor)} — the gate " <>
            "applies only to :server and :client (gating :human is circular; :provider " <>
            "has no pre-exec suspend point)"
  end

  defp validate_gate_matrix!(_executor, _approval), do: :ok

  defp validate_callback!(:server, callback) when is_function(callback, 2), do: :ok

  defp validate_callback!(:server, other) do
    raise ArgumentError, "a :server tool requires a 2-arity :callback, got: #{inspect(other)}"
  end

  defp validate_callback!(_executor, _callback), do: :ok
end
