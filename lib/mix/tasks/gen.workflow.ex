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
    # Keep mount and terminate paired in the generated contract: a detached
    # issue worktree is the resource named by both commands.
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
    mount: mkdir -p "$workspace/$repo_id" && git worktree add --detach "$workspace/$repo_id/$issue" HEAD
    terminate: git worktree remove --force "$workspace/$repo_id/$issue"
    agent:
      vendor: codex
      model: gpt-5.6-sol
      reasoning: high
    ---

    Your session pauses only when the last GitHub issue comment ends with "∎". Use `gh` CLI. If user needs to intervene, explain it in comment and ends with "∎"

    You are responsible with implementation & PR of the issue.

    Workflow is simple:
    - Read CONTRIBUTING.md if exists, follow it, especially with tests before PR.
    - Prefer debugger to understand the nature of the issue. Write debugger script when supported by the debugger.
    - When you could reduce problem into single function, explain it with the name in issue comment, with concise code implementation of it, work on, make PR.

    Branch in git with <service>/<content> branch name, expected to use clean commit messages.

    PR body must detail focusing on the semantics on the implementation you wrote.
    Inline comment is expected for most works. Write assertive comments on abstraction of code you wrote.

    You aren't allowed to merge PR, open PR always in Draft mode.
    """
  end
end
