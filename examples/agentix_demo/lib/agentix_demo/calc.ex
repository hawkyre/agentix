defmodule AgentixDemo.Calc do
  @moduledoc false
  # A deliberately tiny, safe two-operand integer calculator for the demo's `calculator`
  # tool — a regex parse, never `Code.eval` (no injection surface). Anything it can't parse
  # comes back as a friendly message rather than an error.

  @expr ~r/^\s*(-?\d+)\s*([-+*\/])\s*(-?\d+)\s*$/

  @doc "Evaluate `a <op> b` for integers; returns a human-readable result string."
  @spec eval(String.t()) :: String.t()
  def eval(expression) when is_binary(expression) do
    case Regex.run(@expr, expression) do
      [_, a, op, b] -> compute(String.to_integer(a), op, String.to_integer(b), expression)
      _ -> "I can only evaluate a simple 'a op b' expression (e.g. 6 * 7)."
    end
  end

  def eval(_), do: "I can only evaluate a simple 'a op b' expression (e.g. 6 * 7)."

  defp compute(_a, "/", 0, _expr), do: "Can't divide by zero."
  defp compute(a, "/", b, expr), do: "#{expr} = #{a / b}"
  defp compute(a, "*", b, expr), do: "#{expr} = #{a * b}"
  defp compute(a, "+", b, expr), do: "#{expr} = #{a + b}"
  defp compute(a, "-", b, expr), do: "#{expr} = #{a - b}"
end
