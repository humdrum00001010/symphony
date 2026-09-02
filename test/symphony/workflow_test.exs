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
      group: self(),
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
      group: self(),
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

    def command, do: "sleep 100 & wait"
    def handle_message(_message, state), do: {:noreply, state}
  end

  test "starts an agent for a fresh issue" do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-workflow-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(path)
      File.rm(path <> ".json")
    end)

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

    state = %{
      "config" => %{
        "id" => "owner/repo",
        "states" => ["OPEN"],
        "terminal_states" => ["CLOSED"],
        "workspace" => path
      },
      "mount" =>
        "mkdir -p \"$workspace/$repo_id/$issue\"; printf 'mount\\n' >> \"$workspace/mounts\"",
      "terminate" =>
        "rmdir \"$workspace/$repo_id/$issue\"; printf '%s' \"$issue\" > \"$workspace/terminated\"",
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
    }

    state = Workflow.update_issues(state, [%{issue | comments: [%{content: "∎"}]}])
    assert %{issues: [%{session_id: nil}]} = state
    refute File.dir?(Path.join(path, "owner/repo/1"))

    state = Workflow.update_issues(state, [issue])

    assert %{issues: [%{agent: agent, session_id: nil}]} = state

    assert Process.alive?(agent)
    assert File.dir?(Path.join(path, "owner/repo/1"))

    {:os_pid, killed_pid} = agent |> :sys.get_state() |> Map.get(:port) |> Port.info(:os_pid)
    Process.exit(agent, :kill)
    refute Process.alive?(agent)

    state = Workflow.update_issues(state, [issue])

    assert %{issues: [%{agent: restarted}]} = state
    assert restarted != agent
    assert Process.alive?(restarted)
    {_, 1} = System.cmd("kill", ["-0", "-#{killed_pid}"], stderr_to_stdout: true)
    assert File.dir?(Path.join(path, "owner/repo/1"))
    assert File.read!(Path.join(path, "mounts")) == "mount\n"

    Process.exit(restarted, :kill)

    state =
      Workflow.update_issues(state, [
        %{issue | version: "2", comments: [%{content: "∎"}]}
      ])

    assert %{issues: [%{agent: ^restarted}]} = state
    refute Process.alive?(restarted)

    state = Workflow.update_issues(state, [%{issue | version: "3"}])
    assert %{issues: [%{agent: resumed}]} = state
    assert File.read!(Path.join(path, "mounts")) == "mount\n"

    {:os_pid, pid} = resumed |> :sys.get_state() |> Map.get(:port) |> Port.info(:os_pid)
    {_, 0} = System.cmd("kill", ["-0", "-#{pid}"], stderr_to_stdout: true)

    assert %{issues: []} =
             Workflow.update_issues(state, [])

    refute Process.alive?(resumed)
    {_, 1} = System.cmd("kill", ["-0", "-#{pid}"], stderr_to_stdout: true)
    assert File.read!(Path.join(path, "terminated")) == "1"
  end

  test "terminates a stalled mount command" do
    issue = %{
      id: "1",
      state: "OPEN",
      comments: []
    }

    assert catch_exit(
             Workflow.update_issues(
               %{
                 "config" => %{"id" => "owner/repo", "workspace" => System.tmp_dir!()},
                 "timeout" => 10,
                 "mount" => "sleep 100 & wait",
                 agent: AgentProtocol,
                 issues: [],
                 repo: %{terminal_states: []}
               },
               [issue]
             )
           ) == {:command_timeout, "sleep 100 & wait"}
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
              "mount" =>
                "mkdir -p \"$workspace/$repo_id\" && git worktree add --detach \"$workspace/$repo_id/$issue\" HEAD",
              "terminate" => "git worktree remove --force \"$workspace/$repo_id/$issue\"",
              interval: 60_000,
              prompt: prompt,
              supervisor: supervisor
            }, {:continue, :start}} = Workflow.init(path: path, interval: 60_000)

    assert prompt ==
             "Your session pauses only when the last GitHub issue comment ends with \"∎\". Use `gh` CLI.\n\nYou are responsible with implementation & PR of the issue.\n\nWorkflow is simple:\n- Read CONTRIBUTING.md if exists, follow it, especially with tests before PR.\n- Prefer debugger to understand the nature of the issue. Write debugger script when supported by the debugger.\n- When you could reduce problem into single function, explain it with the name in issue comment, work on, make PR.\n\nBranch in git with <service>/<content> branch name, expected to use clean commit messages.\n\nPR body must detail focusing on the semantics on the implementation you wrote.\nInline comment is expected for most works. Write assertive comments on abstraction of code you wrote.\n\nYou aren't allowed to merge PR, open PR always in Draft mode."

    Supervisor.stop(supervisor)
  end
end
