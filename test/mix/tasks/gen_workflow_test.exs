defmodule Mix.Tasks.Gen.WorkflowTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Gen.Workflow
  alias Symphony.Workflow, as: WorkflowRuntime

  setup do
    directory =
      Path.join(System.tmp_dir!(), "symphony-gen-workflow-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{directory: directory}
  end

  test "generates a repository-named workflow", %{directory: directory} do
    output =
      File.cd!(directory, fn ->
        capture_io(fn -> Workflow.run(["owner/example"]) end)
      end)

    path = Path.join(directory, "workflows/example.md")

    assert output == "Generated workflows/example.md\n"

    assert File.read!(path) == """
           ---
           config:
             vendor: github
             id: owner/example
             states:
               - OPEN
             terminal_states:
               - CLOSED
             workspace: ./.symphony/
           mount: mkdir -p "$workspace/$repo_id" && git clone --depth 1 "https://github.com/$repo_id" "$workspace/$repo_id/$issue" 2>/dev/null
           terminate: rm -rf "$workspace/$repo_id/$issue"
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

    assert {:ok,
            %{
              "config" => %{"id" => "owner/example", "vendor" => "github"},
              "mount" =>
                "mkdir -p \"$workspace/$repo_id\" && git clone --depth 1 \"https://github.com/$repo_id\" \"$workspace/$repo_id/$issue\" 2>/dev/null",
              "terminate" => "rm -rf \"$workspace/$repo_id/$issue\"",
              prompt: prompt,
              supervisor: supervisor
            }, {:continue, :start}} = WorkflowRuntime.init(path: path)

    assert prompt ==
             "Your session pauses only when the last GitHub issue comment ends with \"∎\". Use `gh` CLI. If user needs to intervene, explain it in comment and ends with \"∎\"\n\nYou are responsible with implementation & PR of the issue.\n\nWorkflow is simple:\n- Read CONTRIBUTING.md if exists, follow it, especially with tests before PR.\n- Prefer debugger to understand the nature of the issue. Write debugger script when supported by the debugger.\n- When you could reduce problem into single function, explain it with the name in issue comment, with concise code implementation of it, work on, make PR.\n\nBranch in git with <service>/<content> branch name, expected to use clean commit messages.\n\nPR body must detail focusing on the semantics on the implementation you wrote.\nInline comment is expected for most works. Write assertive comments on abstraction of code you wrote.\n\nYou aren't allowed to merge PR, open PR always in Draft mode."

    Supervisor.stop(supervisor)
  end

  test "requires exactly one owner and repository", %{directory: directory} do
    File.cd!(directory, fn ->
      assert_raise Mix.Error, "Expected one repository in OWNER/REPO form", fn ->
        Workflow.run([])
      end

      assert_raise Mix.Error, "Expected one repository in OWNER/REPO form", fn ->
        Workflow.run(["example"])
      end

      assert_raise Mix.Error, "Expected one repository in OWNER/REPO form", fn ->
        Workflow.run(["owner/example", "extra"])
      end
    end)
  end

  test "does not overwrite an existing workflow", %{directory: directory} do
    File.cd!(directory, fn ->
      File.mkdir!("workflows")
      File.write!("workflows/example.md", "maintained workflow")

      assert_raise Mix.Error, "Workflow already exists: workflows/example.md", fn ->
        Workflow.run(["owner/example"])
      end

      assert File.read!("workflows/example.md") == "maintained workflow"
    end)
  end
end
