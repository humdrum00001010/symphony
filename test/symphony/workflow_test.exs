defmodule Symphony.WorkflowTest do
  use ExUnit.Case, async: false

  alias Symphony.Workflow

  defmodule Planner do
    def fetch_issues(%{test: test}) do
      send(test, {:fetch, self()})

      receive do
        {:return, result} -> result
      end
    end
  end

  test "ignores older issue results" do
    path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}")

    issue = %{
      id: "1",
      author: "me",
      title: "Issue",
      content: "Body",
      state: "OPEN",
      version: "0",
      sub_issue: nil,
      comments: [],
      agent: self(),
      session_id: "session"
    }

    state = %{
      interval: 60_000,
      issues: [issue],
      path: path,
      planner: Planner,
      repo: %{test: self(), terminal_states: []},
      version: 0
    }

    {:noreply, state} = Workflow.handle_info(:tick, state)
    assert_receive {:fetch, first}

    {:noreply, state} = Workflow.handle_info(:tick, state)
    assert_receive {:fetch, second}

    send(second, {:return, {:ok, [%{issue | version: "2"} |> Map.drop([:agent, :session_id])]}})
    assert_receive current = {:update, 2, {:ok, _issues}}
    {:noreply, state} = Workflow.handle_info(current, state)

    send(first, {:return, {:ok, [%{issue | version: "1"} |> Map.drop([:agent, :session_id])]}})
    assert_receive stale = {:update, 1, {:ok, _issues}}

    assert {:noreply, ^state} =
             Workflow.handle_info(stale, state)

    assert %{issues: [%{version: "2"}]} = state

    on_exit(fn -> File.rm(path <> ".json") end)
  end

  test "updates only new issue versions" do
    path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}")

    current = %{
      id: "1",
      author: "me",
      title: "Old",
      content: "Body",
      state: "OPEN",
      version: "1",
      sub_issue: nil,
      comments: [],
      agent: self(),
      session_id: "session"
    }

    state = %{
      issues: [current],
      path: path,
      repo: %{id: "owner/repo", states: ["OPEN", "CLOSED"], terminal_states: ["CLOSED"]}
    }

    fresh = current |> Map.delete(:agent) |> Map.delete(:session_id)

    assert ^state = Workflow.update_issues(state, [fresh])
    refute File.exists?(path <> ".json")
    refute_receive {:"$gen_cast", _}

    assert %{issues: [%{title: "New", agent: agent}]} =
             Workflow.update_issues(
               state,
               [%{fresh | title: "New", version: "2"}]
             )

    assert agent == self()
    assert_receive {:"$gen_cast", {:update, %{title: "New", version: "2"}}}

    on_exit(fn -> File.rm(path <> ".json") end)
  end

  defmodule AgentProtocol do
    @behaviour Symphony.Agents.Protocol

    def command, do: "sleep 10"
    def handle_message(_message, state), do: {:noreply, state}
  end

  test "starts an agent for a fresh issue" do
    path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}")

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    issue = %{
      id: "1",
      author: "me",
      title: "Fix",
      content: "Body",
      state: "OPEN",
      version: "1",
      sub_issue: nil,
      comments: []
    }

    state =
      Workflow.update_issues(
        %{
          "config" => %{
            "id" => "owner/repo",
            "states" => ["OPEN"],
            "terminal_states" => ["CLOSED"]
          },
          agent: AgentProtocol,
          issues: [],
          path: path,
          planner: Symphony.Planners.Github,
          prompt: "Solve the issue",
          repo: %{
            id: "owner/repo",
            states: ["OPEN", "CLOSED"],
            terminal_states: ["CLOSED"]
          },
          supervisor: supervisor
        },
        [issue]
      )

    assert %{issues: [%{agent: agent, session_id: nil}]} = state

    assert Process.alive?(agent)

    Process.exit(agent, :kill)
    refute Process.alive?(agent)

    state = Workflow.update_issues(state, [issue])

    assert %{issues: [%{agent: restarted}]} = state
    assert restarted != agent
    assert Process.alive?(restarted)

    assert %{issues: []} =
             Workflow.update_issues(state, [%{issue | state: "CLOSED", version: "2"}])

    refute Process.alive?(restarted)

    on_exit(fn -> File.rm(path <> ".json") end)
  end

  test "assigns each session to one issue" do
    path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path <> ".json") end)

    assert {:reply, :ok,
            %{
              issues: [
                %{id: "1", session_id: "session"},
                %{id: "2", session_id: "other-session"}
              ]
            }} =
             Workflow.handle_call(
               {:update_session, "1", "session"},
               self(),
               %{
                 path: path,
                 issues: [
                   %{id: "1", session_id: nil},
                   %{id: "2", session_id: "other-session"}
                 ]
               }
             )

    assert [
             %{"id" => "1", "session_id" => "session"},
             %{"id" => "2", "session_id" => "other-session"}
           ] = path |> Kernel.<>(".json") |> File.read!() |> JSON.decode!()
  end

  test "loads issue sessions beside the workflow" do
    path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}.md")

    File.write!(
      path,
      """
      ---
      config:
        vendor: github
        id: owner/repo
        states:
          - OPEN
        terminal_states:
          - CLOSED
      agent:
        vendor: codex
      ---

      prompt
      """
    )

    File.write!(path <> ".json", ~s([{"id":"1","session_id":"thread"}]))

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".json")
    end)

    assert {:ok,
            %{
              path: ^path,
              issues: [%{id: "1", session_id: "thread"}],
              supervisor: supervisor
            }, {:continue, :start}} = Workflow.init(path: path)

    Supervisor.stop(supervisor)
  end

  test "loads its workflow file" do
    path = "workflows/WORKFLOW.md"

    assert {:ok,
            %{
              "config" => %{"vendor" => "github"},
              interval: 60_000,
              prompt:
                "Make empty PR corresponding the issue you received.\n\nAppend comment on the issue with \"∎\" when you are done.",
              supervisor: supervisor
            }, {:continue, :start}} = Workflow.init(path: path, interval: 60_000)

    Supervisor.stop(supervisor)
  end
end
