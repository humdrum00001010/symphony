defmodule Mix.Tasks.Gen.Workflow do
  use Mix.Task

  @shortdoc "Generates a workflow for a GitHub repository"

  @moduledoc """
  Generates a workflow for one GitHub repository.

      mix gen.workflow OWNER/REPO

  The workflow is written to `workflows/REPO.md`. Existing workflows are never
  overwritten.
  """

  @impl Mix.Task
  def run([repository]) do
    name = repository_name!(repository)
    path = Path.join("workflows", name <> ".md")

    # The filename is the operator-facing repository identity; the owner stays
    # in the workflow body where GitHub and git require the full repository name.
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, workflow(repository), [:exclusive]) do
      :ok -> Mix.shell().info("Generated #{path}")
      {:error, :eexist} -> Mix.raise("Workflow already exists: #{path}")
      {:error, reason} -> Mix.raise("Could not create #{path}: #{:file.format_error(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("Expected one repository in OWNER/REPO form")
  end

  defp repository_name!(repository) do
    case Regex.run(~r/\A[A-Za-z0-9_.-]+\/([A-Za-z0-9_.-]+)\z/, repository) do
      [^repository, name] -> name
      _ -> Mix.raise("Expected one repository in OWNER/REPO form")
    end
  end

  defp workflow(repository) do
    """
    ---
    config:
      vendor: github
      id: #{repository}
      states:
        - OPEN
      terminal_states:
        - CLOSED
      workspace: ./.symphony/
    mount: git clone --depth 1 https://github.com/#{repository}
    terminate: rm -rf $workspace
    agent:
      vendor: codex
      model: gpt-5.6-sol
      reasoning: high
    ---

    Implement the issue you received and open a pull request.

    Append a comment containing "∎" to the issue when the work is done or cannot proceed.
    """
  end
end
