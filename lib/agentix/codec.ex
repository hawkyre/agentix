defmodule Agentix.Codec do
  @moduledoc """
  JSON ↔ struct codec for the ReqLLM canonical types Agentix persists.

  ReqLLM's `Context`, `Message`, `ContentPart`, `ToolCall`, and `ReasoningDetails`
  all implement `Jason.Encoder`, so **encoding** to the JSON we store in the log is
  free (`encode!/1`). ReqLLM exposes no public JSON→struct path, so this module
  owns **decoding**: `decode_context/1`, `decode_message/1`, and
  `decode_content_part/1` take a JSON-decoded (string-keyed) map and rebuild the
  structs.

  ## Why we rebuild structs from fields

  The decoders are the faithful inverse of ReqLLM's `Jason.Encoder` implementations:
  they map each encoded field back, converting the closed enums (`role`, content
  `type`) and provider atoms from strings, and base64-decoding binary
  `ContentPart` data. ReqLLM's public constructors (`ContentPart.text/2` etc.) are
  lossy for round-tripping — e.g. `file/3` accepts no metadata — so reconstructing
  from the full public field set is the only way to guarantee
  `decode(encode(x)) == x`. The field set is pinned by golden tests so a ReqLLM
  field rename is caught immediately.

  ## What does not round-trip exactly

  Free-form maps (`metadata`, `provider_data`, and tool-call `arguments`) carry
  whatever the provider produced. JSON has no atom keys, so these round-trip as
  **string-keyed** maps — the canonical persisted form. `Context.tools` are not
  persisted (tools are config, rebuilt per agent), so `decode_context/1` returns a
  context with no tools.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.ToolCall

  @doc """
  Encodes `value` (any ReqLLM struct or JSON-able term) to a JSON binary.
  Thin pass-through to `Jason.encode!/1`, kept as the single encode seam.
  """
  @spec encode!(term()) :: binary()
  def encode!(value), do: Jason.encode!(value)

  @doc "Decodes a JSON-decoded map into a `ReqLLM.Context` (messages only)."
  @spec decode_context(map()) :: Context.t()
  def decode_context(%{} = map) do
    map
    |> Map.get("messages", [])
    |> Enum.map(&decode_message/1)
    |> Context.new()
  end

  @doc "Decodes a JSON-decoded map into a `ReqLLM.Message`."
  @spec decode_message(map()) :: Message.t()
  def decode_message(%{} = map) do
    %Message{
      role: decode_role(map["role"]),
      content: decode_each(map["content"], &decode_content_part/1) || [],
      name: map["name"],
      tool_call_id: map["tool_call_id"],
      tool_calls: decode_each(map["tool_calls"], &decode_tool_call/1),
      metadata: map["metadata"] || %{},
      reasoning_details: decode_each(map["reasoning_details"], &decode_reasoning_details/1)
    }
  end

  @doc "Decodes a JSON-decoded map into a `ReqLLM.Message.ContentPart`."
  @spec decode_content_part(map()) :: ContentPart.t()
  def decode_content_part(%{} = map) do
    %ContentPart{
      type: decode_content_type(map["type"]),
      text: map["text"],
      url: map["url"],
      data: decode_data(map["data"]),
      file_id: map["file_id"],
      media_type: map["media_type"],
      filename: map["filename"],
      metadata: map["metadata"] || %{}
    }
  end

  # --- helpers ---

  defp decode_each(nil, _fun), do: nil
  defp decode_each(list, fun) when is_list(list), do: Enum.map(list, fun)

  defp decode_role(role) when role in [:user, :assistant, :system, :tool], do: role
  defp decode_role("user"), do: :user
  defp decode_role("assistant"), do: :assistant
  defp decode_role("system"), do: :system
  defp decode_role("tool"), do: :tool
  defp decode_role(other), do: raise(ArgumentError, "unknown message role: #{inspect(other)}")

  @content_types [:text, :image_url, :video_url, :image, :file, :thinking]

  defp decode_content_type(type) when type in @content_types, do: type
  defp decode_content_type("text"), do: :text
  defp decode_content_type("image_url"), do: :image_url
  defp decode_content_type("video_url"), do: :video_url
  defp decode_content_type("image"), do: :image
  defp decode_content_type("file"), do: :file
  defp decode_content_type("thinking"), do: :thinking

  defp decode_content_type(other) do
    raise ArgumentError, "unknown content part type: #{inspect(other)}"
  end

  # ContentPart's Jason.Encoder base64-encodes binary `data`; reverse it.
  defp decode_data(nil), do: nil
  defp decode_data(data) when is_binary(data), do: Base.decode64!(data)
  defp decode_data(data), do: data

  # A ToolCall encodes as %{"id", "type", "function" => %{"name", "arguments"}}.
  defp decode_tool_call(%{"function" => function} = map) do
    %ToolCall{
      id: map["id"],
      type: map["type"] || "function",
      function: decode_function(function)
    }
  end

  defp decode_function(%{} = function) do
    base = %{name: function["name"], arguments: function["arguments"]}
    if function["builtin?"] == true, do: Map.put(base, :builtin?, true), else: base
  end

  defp decode_reasoning_details(%{} = map) do
    %ReasoningDetails{
      text: map["text"],
      signature: map["signature"],
      encrypted?: map["encrypted?"] || false,
      provider: decode_provider(map["provider"]),
      format: map["format"],
      index: map["index"] || 0,
      provider_data: map["provider_data"] || %{}
    }
  end

  defp decode_provider(nil), do: nil
  defp decode_provider(provider) when is_atom(provider), do: provider
  defp decode_provider(provider) when is_binary(provider), do: String.to_existing_atom(provider)
end
