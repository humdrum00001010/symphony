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
           mount: git clone --depth 1 https://github.com/owner/example
           terminate: rm -rf $workspace
           agent:
             vendor: codex
             model: gpt-5.6-sol
             reasoning: high
           ---

           Implement the issue you received and open a pull request.

           Append a comment containing "∎" to the issue when the work is done or cannot proceed.
           """

    assert {:ok,
            %{
              "config" => %{"id" => "owner/example", "vendor" => "github"},
              prompt:
                "Implement the issue you received and open a pull request.\n\nAppend a comment containing \"∎\" to the issue when the work is done or cannot proceed.",
              supervisor: supervisor
            }, {:continue, :start}} = WorkflowRuntime.init(path: path)

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
