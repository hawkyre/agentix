defmodule AgentixDemo.Calc do
  @moduledoc false
  # A deliberately tiny, safe two-operand integer calculator for the demo's `calculator`
  # tool — a regex parse, never `Code.eval` (no injection surface). Operands are capped at 15
  # digits so a giant number string can't allocate an unbounded bignum. Anything it can't
  # parse comes back as a friendly message rather than an error.

  # {1,15} bounds each operand to a 64-bit-safe size — no unbounded `String.to_integer` bignum.
  @expr ~r/^\s*(-?\d{1,15})\s*([-+*\/])\s*(-?\d{1,15})\s*$/
  @bad_input "I can only evaluate a simple 'a op b' expression (e.g. 6 * 7)."

  @doc "Evaluate `a <op> b` for integers; returns a human-readable result string."
  @spec eval(String.t()) :: String.t()
  def eval(expression) when is_binary(expression) do
    case Regex.run(@expr, expression) do
      [_, a, op, b] -> compute(String.to_integer(a), op, String.to_integer(b), expression)
      _ -> @bad_input
    end
  end

  def eval(_), do: @bad_input

  defp compute(_a, "/", 0, _expr), do: "Can't divide by zero."
  defp compute(a, "/", b, expr) when b != 0, do: "#{expr} = #{div(a, b)}"
  defp compute(a, "*", b, expr), do: "#{expr} = #{a * b}"
  defp compute(a, "+", b, expr), do: "#{expr} = #{a + b}"
  defp compute(a, "-", b, expr), do: "#{expr} = #{a - b}"
end
