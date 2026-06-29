defmodule AgentixDemo.RepoTools do
  @moduledoc false
  # Real, mostly-read-only tools over the Agentix repo, powering the "Agentix explains its own
  # source" demo. Everything is scoped to the repo root: paths are resolved and rejected if they
  # escape it, the search query and file path are passed as argv (never a shell string, so no
  # injection), and output is capped. `run_tests/1` shells out to `mix test` and is the one
  # approval-gated action; under the test suite it's stubbed (config :agentix_demo, :stub_tools).

  @max_bytes 6_000

  @doc "The Agentix repo root (the demo lives two levels down, in examples/agentix_demo)."
  @spec root() :: String.t()
  def root, do: Path.expand("../..", File.cwd!())

  @doc "grep the source (lib + guides) for `query`; returns matching `file:line` snippets."
  @spec search_code(String.t()) :: String.t()
  def search_code(query) when is_binary(query) and query != "" do
    # Prefer ripgrep (gitignore-aware, fast) but fall back to grep so the demo runs on any host
    # without ripgrep installed (e.g. a stock CI runner). Both emit `file:line:` matches.
    case grep(query) do
      {"", _} -> "No matches for #{inspect(query)}."
      {out, 0} -> cap(out)
      {_, _} -> "No matches for #{inspect(query)}."
    end
  end

  def search_code(_), do: "Provide a non-empty search query."

  @doc "Read a repo file (scoped to the repo, capped). Reject anything outside the repo."
  @spec read_file(String.t()) :: String.t()
  def read_file(path) when is_binary(path) do
    with {:ok, abs} <- safe_path(path),
         {:ok, content} <- File.read(abs) do
      cap(content)
    else
      _ -> "Couldn't read #{inspect(path)} — not found, not a file, or outside the repo."
    end
  end

  def read_file(_), do: "Provide a file path relative to the repo root (e.g. lib/agentix/hook.ex)."

  @doc """
  Run a single test file (approval-gated in the UI). Stubbed under the test suite so the demo's
  own tests don't spawn `mix`.
  """
  @spec run_tests(String.t()) :: String.t()
  def run_tests(path) when is_binary(path) do
    cond do
      Application.get_env(:agentix_demo, :stub_tools, false) ->
        "[stubbed] would run: mix test #{path}"

      match?({:ok, _}, safe_test_path(path)) ->
        {:ok, abs} = safe_test_path(path)
        rel = Path.relative_to(abs, root())

        {out, code} =
          System.cmd("mix", ["test", rel, "--max-failures", "3"],
            cd: root(),
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        "exit #{code}\n" <> cap(tail(out, 40))

      true ->
        "I can only run a test file under test/ (e.g. test/agentix/hook_test.exs)."
    end
  end

  def run_tests(_), do: "Provide a test file path (e.g. test/agentix/hook_test.exs)."

  # --- search backend ---

  defp grep(query) do
    case System.find_executable("rg") do
      nil ->
        # `-r` recursive, `-n` line numbers, `-I` skip binaries, `-m 4` cap per file, `-e` so a
        # leading `-` in the query isn't read as a flag. grep prefixes `file:line:` like rg does.
        System.cmd("grep", ["-rIn", "-m", "4", "-e", query, "lib", "guides"],
          cd: root(),
          stderr_to_stdout: true
        )

      rg ->
        System.cmd(
          rg,
          ["--line-number", "--no-heading", "--max-count", "4", "--", query, "lib", "guides"],
          cd: root(),
          stderr_to_stdout: true
        )
    end
  end

  # --- safety helpers ---

  defp safe_path(path) do
    abs = Path.expand(path, root())
    if under_root?(abs) and File.regular?(abs), do: {:ok, abs}, else: :error
  end

  defp safe_test_path(path) do
    with {:ok, abs} <- safe_path(path),
         true <- String.starts_with?(abs, Path.join(root(), "test") <> "/"),
         true <- String.ends_with?(abs, "_test.exs") do
      {:ok, abs}
    else
      _ -> :error
    end
  end

  defp under_root?(abs), do: abs == root() or String.starts_with?(abs, root() <> "/")

  defp cap(text) when byte_size(text) <= @max_bytes, do: text
  defp cap(text), do: binary_part(text, 0, @max_bytes) <> "\n… (truncated)"

  defp tail(text, lines) do
    text |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
  end
end
