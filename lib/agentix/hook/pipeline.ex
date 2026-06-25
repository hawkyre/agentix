defmodule Agentix.Hook.Pipeline do
  @moduledoc false
  # Runs the hook pipelines around a model call.

  alias Agentix.Hook
  alias Agentix.Hook.OverflowError
  alias Agentix.Turn

  require Logger

  @doc """
  Runs the pre-hooks. Returns `{:cont, turn}` (the turn with accumulated injections)
  or `{:halt, reason}`. Raises `Agentix.Hook.OverflowError` if a hook's injection
  pushes the cumulative size past `injection_reserve`. `hook_timeout` bounds each
  parallel pre-hook (ms).
  """
  @spec run_pre(Turn.t(), [Hook.t()], pos_integer(), pos_integer()) ::
          {:cont, Turn.t()} | {:halt, term()}
  def run_pre(%Turn{} = turn, hooks, injection_reserve, hook_timeout) do
    {sequential, parallel} = Enum.split_with(hooks, &(&1.mode == :sequential))

    case run_sequential(turn, sequential, injection_reserve) do
      {:halt, reason} -> {:halt, reason}
      {:cont, turn} -> {:cont, run_parallel(turn, parallel, injection_reserve, hook_timeout)}
    end
  end

  @doc """
  Runs the post-hooks sequentially. Returns `{:cont, turn}` or `{:halt, reason}`.
  """
  @spec run_post(Turn.t(), [Hook.t()]) :: {:cont, Turn.t()} | {:halt, term()}
  def run_post(%Turn{} = turn, hooks), do: run_sequential(turn, hooks, nil)

  # Sequential fold shared by pre and post: short-circuit on `:halt`, fold the turn on
  # `:cont`. A non-nil `reserve` (pre only) names the offending hook in the
  # `OverflowError` if its injection pushes the cumulative size over the limit.
  defp run_sequential(turn, [], _reserve), do: {:cont, turn}

  defp run_sequential(turn, [hook | rest], reserve) do
    case hook.run.(turn) do
      {:cont, %Turn{} = turn} ->
        if reserve, do: check_reserve!(turn, hook, reserve)
        run_sequential(turn, rest, reserve)

      {:halt, reason} ->
        {:halt, reason}

      other ->
        raise ArgumentError,
              "hook #{inspect(hook.name)} must return {:cont, %Turn{}} or {:halt, reason}, " <>
                "got: #{inspect(other)}"
    end
  end

  # Parallel append-only pre-hooks: spawn all (concurrent, unlinked under the
  # TaskSupervisor), then collect in declaration order. `async_nolink` + `yield`/
  # `shutdown` (not `await`) contains a hook that *exits* or hangs as a skipped-error
  # result instead of taking the agent down; the reserve is checked per contributor.
  defp run_parallel(turn, [], _reserve, _timeout), do: turn

  defp run_parallel(turn, hooks, reserve, timeout) do
    hooks
    |> Enum.map(fn hook ->
      {hook, Task.Supervisor.async_nolink(Agentix.TaskSupervisor, fn -> safe_run(hook, turn) end)}
    end)
    |> Enum.reduce(turn, fn {hook, task}, acc ->
      collect_parallel(acc, hook, await_hook(task, timeout), reserve)
    end)
  end

  defp await_hook(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, %RuntimeError{message: "hook exited: #{inspect(reason)}"}}
      nil -> {:error, %RuntimeError{message: "hook timed out after #{timeout}ms"}}
    end
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

  # Sized via the shared Agentix.Tokenizer so the injection reserve and the
  # compaction budget speak the same units. Non-text parts cost 0 here.
  defp injection_tokens(parts), do: parts |> Enum.map(&part_tokens/1) |> Enum.sum()

  defp part_tokens(%{text: text}) when is_binary(text), do: Agentix.Tokenizer.count(text)
  defp part_tokens(_part), do: 0
end
