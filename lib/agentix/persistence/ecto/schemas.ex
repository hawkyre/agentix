# Compiles only when Ecto is available (the adapter is an optional dependency). A host
# without `:ecto_sql` simply never gets these modules; configuring the Ecto adapter
# without the dep raises a clear error from `Agentix.Persistence.Ecto`.
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Agentix.Persistence.Ecto.Conversation do
    @moduledoc false
    use Ecto.Schema

    # Conversation ids are arbitrary host-chosen strings (the Registry key), not UUIDs.
    @primary_key {:id, :string, autogenerate: false}
    schema "agentix_conversations" do
      field(:settings, :map, default: %{})
      field(:fsm_state, :map, default: %{})
      field(:status, Ecto.Enum, values: [:active, :suspended, :idle, :ended], default: :active)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Agentix.Persistence.Ecto.Event do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "agentix_events" do
      field(:conversation_id, :string)
      field(:seq, :integer)

      field(:type, Ecto.Enum,
        values: [:user_msg, :assistant_msg, :tool_call, :tool_result, :suspension, :resolution]
      )

      field(:content, :map)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  defmodule Agentix.Persistence.Ecto.Summary do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "agentix_summaries" do
      field(:conversation_id, :string)
      field(:from_seq, :integer)
      field(:to_seq, :integer)
      field(:content, :map)
      field(:version, :string)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  defmodule Agentix.Persistence.Ecto.ToolCall do
    @moduledoc false
    use Ecto.Schema

    # The primary key is the provider-supplied tool_call_id (the correlation key).
    @primary_key {:id, :string, autogenerate: false}
    @foreign_key_type :binary_id
    schema "agentix_tool_calls" do
      field(:conversation_id, :string)
      field(:executor, Ecto.Enum, values: [:server, :human, :client, :provider])

      field(:status, Ecto.Enum,
        values: [:pending, :resolved, :errored, :expired],
        default: :pending
      )

      field(:args, :map)
      field(:result, :map)
      field(:inserted_at, :utc_datetime_usec)
      field(:resolved_at, :utc_datetime_usec)
    end
  end

  defmodule Agentix.Persistence.Ecto.ModelCall do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "agentix_model_calls" do
      field(:conversation_id, :string)
      field(:turn_ref, :integer)
      field(:rendered_context, :map)
      field(:model, :string)
      field(:usage, :map)
      field(:latency_ms, :integer)
      field(:summary_version, :string)
      field(:evictions, {:array, :map})
      field(:inserted_at, :utc_datetime_usec)
    end
  end
end
