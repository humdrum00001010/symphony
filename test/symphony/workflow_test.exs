defmodule Symphony.WorkflowTest do
  use ExUnit.Case, async: true

  alias Symphony.Workflow

  test "starts from its path and polling interval" do
    workflow =
      start_supervised!({Workflow, path: "first.md", interval: 60_000})

    assert %{path: "first.md", interval: 60_000} = :sys.get_state(workflow)
  end

  test "starts more than one workflow under the same supervisor" do
    {:ok, supervisor} =
      ["first.md", "second.md"]
      |> Enum.map(fn path ->
        Supervisor.child_spec({Workflow, path: path}, id: path)
      end)
      |> Supervisor.start_link(strategy: :one_for_one)

    assert %{active: 2, workers: 2} = Supervisor.count_children(supervisor)
  end
end
