defmodule Agentix.ComponentsTest do
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

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

  describe "message_list/1 — one header per assistant turn" do
    test "a user→assistant→tool→assistant turn renders a single Assistant header and no Tool header" do
      messages = [
        {"m1", %Message{role: :user, content: [ContentPart.text("use a tool")]}},
        {"m2", %Message{role: :assistant, content: [ContentPart.text("Let me look that up.")]}},
        {"m3",
         %Message{
           role: :tool,
           tool_call_id: "t1",
           content: [ContentPart.text(~s({"ok":true}))],
           metadata: %{"tool_name" => "lookup", "tool_status" => "ok"}
         }},
        {"m4", %Message{role: :assistant, content: [ContentPart.text("Done — 42.")]}}
      ]

      html = render_component(&Agentix.Components.message_list/1, id: "msgs", messages: messages)

      # The three agent rows (assistant text, tool, assistant text) share one group; the
      # user message is its own group. Grouping is what collapses them under one header.
      assert count(html, ~s(data-group="agent")) == 3
      assert count(html, ~s(data-group="user")) == 1

      # The tool row never renders its own "Tool" header — it's a named, headerless card.
      assert html =~ "lookup"
      refute html =~ ">Tool<"

      # Only the user + assistant rows carry a role-header element (the tool row has none);
      # the CSS hides every one that follows another agent row, so one header shows per turn.
      assert count(html, "agentix-role-header") == 3

      assert Agentix.Components.css() =~
               ~s([data-group="agent"] + [data-group="agent"] .agentix-role-header)
    end
  end

  describe "message/1 — tool rows" do
    test "an errored tool with no name renders the error state and the 'tool' fallback label" do
      assigns = %{
        message: %Message{
          role: :tool,
          tool_call_id: "t1",
          content: [],
          metadata: %{"tool_status" => "error"}
        }
      }

      html =
        rendered_to_string(~H"""
        <Agentix.Components.message message={@message} />
        """)

      # status drives the error styling + label; a missing name falls back to "tool".
      assert html =~ "error"
      assert html =~ "tool"
      assert html =~ "red"
      # tool rows never render a role header.
      refute html =~ "agentix-role-header"
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
