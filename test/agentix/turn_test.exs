defmodule Agentix.TurnTest do
  use ExUnit.Case, async: true

  alias Agentix.Scope
  alias Agentix.Turn

  test "new/0 defaults to a fresh scope and nil fields" do
    turn = Turn.new()
    assert %Scope{} = turn.scope
    assert turn.context == nil
    assert turn.user_message == nil
    assert turn.turn_ref == nil
  end

  test "new/1 keeps a supplied scope and fields" do
    scope = Scope.new(current_user: :bob)
    turn = Turn.new(context: :ctx, user_message: :msg, turn_ref: 3, scope: scope)
    assert turn.scope == scope
    assert turn.context == :ctx
    assert turn.user_message == :msg
    assert turn.turn_ref == 3
  end
end
