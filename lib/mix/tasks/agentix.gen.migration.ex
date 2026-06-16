defmodule Mix.Tasks.Agentix.Gen.Migration do
  @shortdoc "Copies Agentix's Ecto migration into your repo's migrations directory"

  @moduledoc """
  Copies the Agentix tables migration into your repo so the Ecto/Postgres persistence
  adapter (`Agentix.Persistence.Ecto`) has its schema.

      mix agentix.gen.migration
      mix agentix.gen.migration priv/repo/migrations

  Writes a timestamped `*_create_agentix_tables.exs` under the given directory (default
  `priv/repo/migrations`); then run `mix ecto.migrate`. The Ecto-backed suspension expiry
  additionally needs Oban's own migration (see Oban's docs).
  """

  use Mix.Task

  @template "priv/templates/migration/create_agentix_tables.exs"
  @default_dir Path.join(~w(priv repo migrations))

  @impl Mix.Task
  def run(args) do
    {_opts, paths} = OptionParser.parse!(args, strict: [])
    dir = List.first(paths) || @default_dir

    case Path.wildcard(Path.join(dir, "*_create_agentix_tables.exs")) do
      [existing | _] ->
        # The migration's module name is fixed, so a second copy (a re-run) would clash on
        # compile and break `mix ecto.migrate`. Skip rather than write a conflicting file.
        Mix.shell().info([:yellow, "* skipping ", :reset, "#{existing} already exists"])
        existing

      [] ->
        contents = :agentix |> Application.app_dir(@template) |> File.read!()
        File.mkdir_p!(dir)
        target = Path.join(dir, "#{timestamp()}_create_agentix_tables.exs")
        File.write!(target, contents)
        Mix.shell().info([:green, "* creating ", :reset, target])
        target
    end
  end

  # Ecto's migration timestamp format: UTC, second resolution, zero-padded.
  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    [y, m, d, hh, mm, ss]
    |> Enum.zip([4, 2, 2, 2, 2, 2])
    |> Enum.map_join(fn {value, width} ->
      value |> Integer.to_string() |> String.pad_leading(width, "0")
    end)
  end
end
