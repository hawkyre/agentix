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

  test "new/1 raises on unknown keys" do
    assert_raise KeyError, fn -> Scope.new(curent_user: :typo) end
  end

  test "new/1 rejects a system scope carrying a current_user" do
    assert_raise ArgumentError, ~r/system scope cannot carry/, fn ->
      Scope.new(system?: true, current_user: :alice)
    end
  end

  test "system/0 is the system scope with no user or assigns" do
    scope = Scope.system()
    assert scope.system? == true
    assert scope.current_user == nil
    assert scope.assigns == %{}
  end
end
