defmodule Mix.Tasks.Agentix.Gen.Components do
  @shortdoc "Copies Agentix's chat components into your project to own and customize"

  @moduledoc """
  Copies the default `Agentix.Chat` components into your project so you can edit the
  markup directly (an alternative to `import Agentix.Components`).

      mix agentix.gen.components lib/my_app_web/components
      mix agentix.gen.components lib/my_app_web/components --module MyAppWeb.AgentixComponents

  Writes one module file under the given directory. With no `--module`, the module is
  `AgentixComponents`; otherwise the file is named after the module's last segment. An
  existing file is left untouched (you own it after copying) unless you pass `--force`.
  """

  use Mix.Task

  @template "priv/templates/components/agentix_components.ex"

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [module: :string, force: :boolean])
    dir = path!(paths)
    module = opts[:module] || "AgentixComponents"

    contents =
      :agentix
      |> Application.app_dir(@template)
      |> File.read!()
      |> rename_module(module)

    File.mkdir_p!(dir)
    target = Path.join(dir, file_name(module))

    if File.exists?(target) and not Keyword.get(opts, :force, false) do
      # The host owns and edits this file once copied — don't clobber their changes on a
      # re-run (e.g. after a library upgrade). Pass `--force` to overwrite.
      Mix.shell().info([:yellow, "* exists ", :reset, "#{target} (use --force to overwrite)"])
    else
      File.write!(target, contents)
      Mix.shell().info([:green, "* creating ", :reset, target])
    end

    target
  end

  defp path!([dir | _]), do: dir

  defp path!([]) do
    Mix.raise("expected a target directory: mix agentix.gen.components DIR [--module MODULE]")
  end

  defp rename_module(contents, "AgentixComponents"), do: contents

  defp rename_module(contents, module),
    do: String.replace(contents, "defmodule AgentixComponents do", "defmodule #{module} do")

  defp file_name(module),
    do: (module |> String.split(".") |> List.last() |> Macro.underscore()) <> ".ex"
end
