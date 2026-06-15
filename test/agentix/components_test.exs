defmodule Agentix.ComponentsTest do
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  describe "message_list/1 — pending controls switch on kind" do
    test "an :approval renders approve/deny controls and an :elicitation renders a form" do
      pending = %{
        "a" => %{executor: :server, kind: :approval, prompt: %{}},
        "b" => %{executor: :human, kind: :elicitation, prompt: %{}}
      }

      html = render_component(&Agentix.Components.message_list/1, id: "msgs", pending: pending)

      # The gated :server approval gets buttons; the :human elicitation gets a form —
      # the switch is on `kind`, not the executor.
      assert html =~ ~s(phx-click="approve")
      assert html =~ ~s(phx-click="deny")
      assert html =~ "<form"
      assert html =~ ~s(phx-submit="resolve")
    end
  end

  describe "message/1 — :bubble slot" do
    test "a custom :bubble slot replaces the default bubble" do
      assigns = %{message: %Message{role: :assistant, content: [ContentPart.text("default-text")]}}

      html =
        rendered_to_string(~H"""
        <Agentix.Components.message message={@message}>
          <:bubble>custom-bubble</:bubble>
        </Agentix.Components.message>
        """)

      assert html =~ "custom-bubble"
      refute html =~ "default-text"
    end

    test "without a slot the default body renders the role label and message text" do
      assigns = %{message: %Message{role: :user, content: [ContentPart.text("hello there")]}}

      html =
        rendered_to_string(~H"""
        <Agentix.Components.message message={@message} />
        """)

      assert html =~ "hello there"
      assert html =~ "You"
    end
  end

  describe "mix agentix.gen.components" do
    test "copies a component module that compiles" do
      dir = Path.join(System.tmp_dir!(), "agentix-gen-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      target = Mix.Tasks.Agentix.Gen.Components.run([dir])

      assert target == Path.join(dir, "agentix_components.ex")
      assert File.exists?(target)
      assert [{AgentixComponents, _binary}] = Code.compile_file(target)
    end
  end
end
