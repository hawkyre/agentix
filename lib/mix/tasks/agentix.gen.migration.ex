defmodule Mix.Tasks.Agentix.Gen.Migration do
  @shortdoc "Copies Agentix's Ecto migration into your repo's migrations directory"

  @moduledoc """
  Copies the Agentix tables migration into your repo so the Ecto/Postgres persistence
  adapter (`Agentix.Persistence.Ecto`) has its schema.

      mix agentix.gen.migration
      mix agentix.gen.migration priv/repo/migrations --repo MyApp.Repo

  Writes a timestamped `*_create_agentix_tables.exs` under the given directory (default
  `priv/repo/migrations`); then run `mix ecto.migrate`. The migration module is namespaced
  under your repo — inferred from the host app name, or set explicitly with `--repo`. The
  Ecto-backed suspension expiry additionally needs Oban's own migration (see Oban's docs).
  """

  use Mix.Task

  @template "priv/templates/migration/create_agentix_tables.exs"
  @default_dir Path.join(~w(priv repo migrations))

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [repo: :string])
    dir = List.first(paths) || @default_dir

    case Path.wildcard(Path.join(dir, "*_create_agentix_tables.exs")) do
      [existing | _] ->
        # The migration's module name is fixed, so a second copy (a re-run) would clash on
        # compile and break `mix ecto.migrate`. Skip rather than write a conflicting file.
        Mix.shell().info([:yellow, "* skipping ", :reset, "#{existing} already exists"])
        existing

      [] ->
        contents =
          :agentix
          |> Application.app_dir(@template)
          # Land the migration under the host's repo namespace, not Agentix's.
          |> File.read!()
          |> String.replace("Agentix.Repo.Migrations", "#{migrations_namespace(opts[:repo])}")

        File.mkdir_p!(dir)
        target = Path.join(dir, "#{timestamp()}_create_agentix_tables.exs")
        File.write!(target, contents)
        Mix.shell().info([:green, "* creating ", :reset, target])
        target
    end
  end

  # The host's migrations module namespace (e.g. `MyApp.Repo.Migrations`): from `--repo`,
  # else inferred from the host app name.
  defp migrations_namespace(nil) do
    app = Mix.Project.config()[:app] || :my_app
    "#{app |> to_string() |> Macro.camelize()}.Repo.Migrations"
  end

  defp migrations_namespace(repo), do: "#{repo}.Migrations"

  # Ecto's migration timestamp format: UTC, second resolution, zero-padded.
  defp timestamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
end
