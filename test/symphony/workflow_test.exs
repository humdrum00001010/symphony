defmodule Symphony.WorkflowTest do
  use ExUnit.Case, async: true

  alias Symphony.Workflow

  test "updates only new issue versions" do
    current = %{
      id: "1",
      version: "1"
    }

    assert %{issues: [^current, %{id: "2", version: "1"}]} =
             Workflow.update_issues(
               %{issues: [current]},
               [
                 %{id: "1", version: "1"},
                 %{id: "2", version: "1"}
               ]
             )

    assert %{issues: [%{id: "1", version: "2"}]} =
             Workflow.update_issues(
               %{issues: [current]},
               [%{id: "1", version: "2"}]
             )
  end

  test "starts from its workflow file" do
    path = "workflows/WORKFLOW.md"

    workflow =
      start_supervised!({Workflow, path: path, interval: 60_000})

    assert %{
             "config" => %{"vendor" => "github"},
             interval: 60_000,
             prompt: "prompts..."
           } = :sys.get_state(workflow)
  end

  test "starts more than one workflow under the same supervisor" do
    path = "workflows/WORKFLOW.md"

    {:ok, supervisor} =
      [
        Supervisor.child_spec({Workflow, path: path}, id: :first),
        Supervisor.child_spec({Workflow, path: path}, id: :second)
      ]
      |> Supervisor.start_link(strategy: :one_for_one)

    assert %{active: 2, workers: 2} = Supervisor.count_children(supervisor)
  end
end
