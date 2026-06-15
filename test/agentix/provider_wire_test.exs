defmodule Agentix.ProviderWireTest do
  @moduledoc """
  Pins the provider-encoding behaviour that makes `Agentix.Agent`'s model-boundary
  metadata strip load-bearing: the OpenAI-format encoder serializes `Message.metadata`
  verbatim onto the wire, while the Anthropic encoder does not. Agentix must therefore
  strip its internal bookkeeping itself rather than rely on any one provider being safe.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults

  @sentinel "ZZ_LEAK_SENTINEL_ZZ"

  defp tool_message(metadata),
    do: %Message{
      role: :tool,
      tool_call_id: "t1",
      content: [ContentPart.text("r")],
      metadata: metadata
    }

  defp openai_json(context),
    do: context |> Defaults.encode_context_to_openai_format("gpt-x") |> Jason.encode!()

  defp anthropic_json(context),
    do: context |> ReqLLM.Providers.Anthropic.Context.encode_request("claude-x") |> Jason.encode!()

  describe "the provider divergence the strip protects against" do
    test "control — the OpenAI-format encoder serializes Message.metadata verbatim" do
      context = Context.new([tool_message(%{"x" => @sentinel})])
      # This is why the leak existed: any non-empty metadata reaches the wire.
      assert openai_json(context) =~ @sentinel
    end

    test "the Anthropic encoder does NOT serialize arbitrary Message.metadata" do
      context = Context.new([tool_message(%{"x" => @sentinel})])
      refute anthropic_json(context) =~ @sentinel
    end

    test "with metadata stripped, neither provider's wire carries it" do
      context = Context.new([tool_message(%{})])
      refute openai_json(context) =~ @sentinel
      refute anthropic_json(context) =~ @sentinel
      # A clean message produces no `metadata` field at all in the OpenAI body.
      body = Defaults.encode_context_to_openai_format(context, "gpt-x")
      assert Enum.all?(body.messages, &(not Map.has_key?(&1, :metadata)))
    end
  end
end
