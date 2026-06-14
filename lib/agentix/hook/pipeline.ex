defmodule Agentix.Hook.Pipeline do
  @moduledoc """
  Runs the hook pipelines around a model call (D7).

  `run_pre/3` runs the pre-hooks against the assembled turn: sequential hooks first
  (in declaration order, each may transform the turn or `:halt`, short-circuiting the
  rest), then parallel append-only hooks concurrently (their `[ContentPart]` outputs
  appended in declaration order). After every hook that injects, the cumulative
  injection is checked against `injection_reserve`; an overflow raises
  `Agentix.Hook.OverflowError` naming that hook (the check happens once — compaction
  is never re-entered, D7).

  `run_post/2` runs the post-hooks sequentially after the assistant message finalizes.

  A pre-hook injects by appending to `turn.injections` via `Agentix.Hook.inject/2`;
  the agent places those parts at the context tail at assembly time (cache-prefix
  safety). v0 sizes injections with a `byte/4` token heuristic; Inc 8's
  `Agentix.Tokenizer` behaviour will replace it (see inc-7-notes).
  """

  alias Agentix.Hook
  alias Agentix.Hook.OverflowError
  alias Agentix.Turn

  require Logger

  @doc """
  Runs the pre-hooks. Returns `{:cont, turn}` (the turn with accumulated injections)
  or `{:halt, reason}`. Raises `Agentix.Hook.OverflowError` if a hook's injection
  pushes the cumulative size past `injection_reserve`.
  """
  @spec run_pre(Turn.t(), [Hook.t()], pos_integer()) :: {:cont, Turn.t()} | {:halt, term()}
  def run_pre(%Turn{} = turn, hooks, injection_reserve) do
    {sequential, parallel} = Enum.split_with(hooks, &(&1.mode == :sequential))

    case run_sequential(turn, sequential, injection_reserve) do
      {:halt, reason} -> {:halt, reason}
      {:cont, turn} -> {:cont, run_parallel(turn, parallel, injection_reserve)}
    end
  end

  @doc """
  Runs the post-hooks sequentially. Returns `{:cont, turn}` or `{:halt, reason}`.
  """
  @spec run_post(Turn.t(), [Hook.t()]) :: {:cont, Turn.t()} | {:halt, term()}
  def run_post(%Turn{} = turn, hooks), do: run_sequential_post(turn, hooks)

  # Sequential pre-hooks: fold the turn, short-circuit on :halt, reserve-check after
  # each (a hook that injects over the reserve is named in the raised OverflowError).
  defp run_sequential(turn, [], _reserve), do: {:cont, turn}

  defp run_sequential(turn, [hook | rest], reserve) do
    case hook.run.(turn) do
      {:cont, %Turn{} = turn} ->
        check_reserve!(turn, hook, reserve)
        run_sequential(turn, rest, reserve)

      {:halt, reason} ->
        {:halt, reason}

      other ->
        raise ArgumentError,
              "sequential pre-hook #{inspect(hook.name)} must return {:cont, %Turn{}} or " <>
                "{:halt, reason}, got: #{inspect(other)}"
    end
  end

  defp run_sequential_post(turn, []), do: {:cont, turn}

  defp run_sequential_post(turn, [hook | rest]) do
    case hook.run.(turn) do
      {:cont, %Turn{} = turn} ->
        run_sequential_post(turn, rest)

      {:halt, reason} ->
        {:halt, reason}

      other ->
        raise ArgumentError,
              "post-hook #{inspect(hook.name)} must return {:cont, %Turn{}} or {:halt, reason}, " <>
                "got: #{inspect(other)}"
    end
  end

  # Parallel append-only pre-hooks: spawn all (concurrent), then collect in
  # declaration order. Each runs inside a try/rescue so a crashing injector is logged
  # and skipped rather than killing the agent; the reserve is checked per contributor.
  defp run_parallel(turn, [], _reserve), do: turn

  defp run_parallel(turn, hooks, reserve) do
    hooks
    |> Enum.map(fn hook -> {hook, Task.async(fn -> safe_run(hook, turn) end)} end)
    |> Enum.reduce(turn, fn {hook, task}, acc ->
      collect_parallel(acc, hook, Task.await(task), reserve)
    end)
  end

  defp safe_run(hook, turn) do
    {:ok, hook.run.(turn)}
  rescue
    e -> {:error, e}
  end

  defp collect_parallel(turn, hook, {:ok, {:cont, parts}}, reserve) when is_list(parts) do
    turn = Hook.inject(turn, parts)
    check_reserve!(turn, hook, reserve)
    turn
  end

  defp collect_parallel(_turn, hook, {:ok, other}, _reserve) do
    raise ArgumentError,
          "parallel pre-hook #{inspect(hook.name)} must return {:cont, [ContentPart]}, " <>
            "got: #{inspect(other)}"
  end

  defp collect_parallel(turn, hook, {:error, error}, _reserve) do
    Logger.error(
      "agentix parallel pre-hook #{inspect(hook.name)} crashed: " <> Exception.message(error)
    )

    turn
  end

  defp check_reserve!(%Turn{injections: injections}, hook, reserve) do
    size = injection_tokens(injections)

    if size > reserve do
      raise OverflowError, hook: hook.name, reserve: reserve, size: size
    end

    :ok
  end

  # v0 token heuristic: byte/4 over text parts (non-text parts cost 0 here). Converges
  # with Inc 8's Agentix.Tokenizer.
  defp injection_tokens(parts) do
    Enum.reduce(parts, 0, fn part, acc -> acc + part_tokens(part) end)
  end

  defp part_tokens(%{text: text}) when is_binary(text), do: div(byte_size(text), 4)
  defp part_tokens(_part), do: 0
end
