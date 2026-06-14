defmodule Agentix.ScopeTest do
  use ExUnit.Case, async: true

  alias Agentix.Scope

  test "new/0 builds an empty, non-system scope" do
    scope = Scope.new()
    assert scope.current_user == nil
    assert scope.system? == false
    assert scope.assigns == %{}
  end

  test "new/1 accepts a keyword list or a map" do
    assert Scope.new(current_user: :alice).current_user == :alice
    assert Scope.new(%{assigns: %{tenant: 1}}).assigns == %{tenant: 1}
  end

  test "system/0 is flagged as the system scope" do
    assert Scope.system().system? == true
  end
end
