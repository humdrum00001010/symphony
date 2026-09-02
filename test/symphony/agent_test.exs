defmodule Symphony.AgentTest do
  use ExUnit.Case, async: false

  alias Symphony.Agent
  alias Symphony.Agents.Codex

  defmodule Workflow do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call(message, _from, test) do
      send(test, message)
      {:reply, :ok, test}
    end
  end

  test "starts a new Codex session when resume fails" do
    directory =
      Path.join(System.tmp_dir!(), "symphony-codex-#{System.unique_integer([:positive])}")

    codex = Path.join(directory, "codex")
    gh = Path.join(directory, "gh")
    runs = Path.join(directory, "runs")
    messages = Path.join(directory, "messages")
    checks = Path.join(directory, "checks")
    cwd = Path.join(directory, "cwd")
    path = System.fetch_env!("PATH")

    File.mkdir!(directory)

    File.write!(
      codex,
      ~S"""
      #!/bin/sh
      printf 'run\n' >> "$CODEX_RUNS"
      pwd > "$CODEX_CWD"

      while IFS= read -r message
      do
        printf '%s\n' "$message" >> "$CODEX_MESSAGES"

        case "$message" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":0,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":1,"result":{"thread":{"id":"thread-1"}}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"missing thread"}}'
            ;;
          *'"method":"turn/start"'*)
            turns=$(($(cat "$CODEX_TURNS" 2>/dev/null || printf 0) + 1))
            printf '%s' "$turns" > "$CODEX_TURNS"
            printf '{"method":"turn/completed","params":{"turn":{"id":"turn-%s","status":"completed","items":[],"error":null}}}\n' "$turns"
            ;;
        esac
      done
      """
    )

    File.write!(
      gh,
      ~S"""
      #!/bin/sh
      checks=$(($(cat "$GH_CHECKS" 2>/dev/null || printf 0) + 1))
      printf '%s' "$checks" > "$GH_CHECKS"
      if [ "$checks" -eq 1 ]; then
        body='continue'
      else
      body='∎'
      fi
      printf '{"number":1,"author":{"login":"me"},"title":"Fix","body":"Body","state":"OPEN","updatedAt":"2026-01-02T00:00:00Z","comments":[{"id":"comment-1","author":{"login":"me"},"body":"%s","createdAt":"2026-01-01T00:00:00Z"}]}' "$body"
      """
    )

    File.chmod!(codex, 0o755)
    File.chmod!(gh, 0o755)
    System.put_env("PATH", directory <> ":" <> path)
    System.put_env("CODEX_RUNS", runs)
    System.put_env("CODEX_MESSAGES", messages)
    System.put_env("CODEX_TURNS", Path.join(directory, "turns"))
    System.put_env("GH_CHECKS", checks)
    System.put_env("CODEX_CWD", cwd)

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("CODEX_RUNS")
      System.delete_env("CODEX_MESSAGES")
      System.delete_env("CODEX_TURNS")
      System.delete_env("GH_CHECKS")
      System.delete_env("CODEX_CWD")
      File.rm_rf!(directory)
    end)

    {:ok, agent} =
      Agent.start_link(%{
        session_id: "missing-thread",
        port: nil,
        agent: Symphony.Agents.Codex,
        prompt: "Fix the issue",
        issue: "1",
        workflow: start_supervised!({Workflow, self()}),
        planner: Symphony.Planners.Github,
        repo: %{id: "owner/repo", states: ["Open"], terminal_states: ["CLOSED"]},
        workspace: directory
      })

    reference = Process.monitor(agent)

    assert 1..100
           |> Enum.any?(fn _ ->
             Process.sleep(10)

             not Process.alive?(agent)
           end)

    assert_receive {:DOWN, ^reference, :process, ^agent, :normal}
    assert_receive {:update_session, "1", nil}
    assert_receive {:update_session, "1", "thread-1"}
    assert File.read!(runs) == "run\n"

    assert (cwd |> File.read!() |> String.trim() |> File.stat!()).inode ==
             (directory |> File.stat!()).inode

    assert File.read!(messages) =~ "\"method\":\"thread/resume\""
    assert File.read!(messages) =~ "\"excludeTurns\":true"
    assert File.read!(messages) =~ "\"method\":\"thread/start\""
    assert File.read!(messages) =~ "\"approvalPolicy\":\"never\""
    assert File.read!(messages) =~ "\"type\":\"dangerFullAccess\""
    assert File.read!(messages) =~ "\"text\":\"I think I said enough.\""
    assert File.read!(messages) |> String.split("\"method\":\"turn/start\"") |> length() == 3
    assert File.read!(messages) |> String.split("Fix the issue") |> length() == 2
    assert File.read!(checks) == "2"
  end

  test "buffers partial Codex messages" do
    assert {:noreply, state = %{buffer: ~s({"id":0)}} =
             Codex.handle_message({:port, {:data, ~s({"id":0)}}, %{port: :port})

    assert {:noreply, %{buffer: ""}} =
             Codex.handle_message({:port, {:data, ~s(,"result":{}}\n)}}, state)

    assert_receive %{"id" => 0, "result" => %{}}
  end

  test "steers the latest update after the turn starts" do
    port = Port.open({:spawn, "cat"}, [:binary])

    assert {:noreply, state = %{pending: :issue_updated}} =
             Codex.handle_message({:update, :issue_updated}, %{
               port: port,
               session_id: "thread"
             })

    assert {:noreply, state = %{issue_notification_in_flight: true, turn_id: "turn"}} =
             Codex.handle_message(
               %{"id" => 3, "result" => %{"turn" => %{"id" => "turn"}}},
               state
             )

    assert_receive {^port, {:data, message}}

    assert %{
             "method" => "turn/steer",
             "params" => %{
               "input" => [
                 %{
                   "text" =>
                     "Issue was updated. Re-read the issue with `gh` and act on the latest state."
                 }
               ]
             }
           } = message |> String.trim() |> JSON.decode!()

    assert {:noreply, state} = Codex.handle_message(%{"id" => 4, "result" => %{}}, state)
    refute Map.has_key?(state, :issue_notification_in_flight)

    Port.close(port)
  end

  test "retries an issue update when steering misses the active turn" do
    port = Port.open({:spawn, "cat"}, [:binary])

    assert {:noreply, state = %{issue_notification_in_flight: true}} =
             Codex.handle_message({:update, :issue_updated}, %{
               port: port,
               session_id: "thread",
               turn_id: "completed-turn"
             })

    assert_receive {^port, {:data, _message}}

    assert {:noreply, state = %{pending: :issue_updated}} =
             Codex.handle_message(%{"id" => 4, "error" => %{}}, state)

    refute Map.has_key?(state, :turn_id)

    assert {:noreply, state = %{issue_notification_in_flight: true, turn_id: "next-turn"}} =
             Codex.handle_message(
               %{"id" => 3, "result" => %{"turn" => %{"id" => "next-turn"}}},
               state
             )

    assert_receive {^port, {:data, message}}

    assert %{
             "method" => "turn/steer",
             "params" => %{"expectedTurnId" => "next-turn"}
           } = message |> String.trim() |> JSON.decode!()

    assert {:noreply, state} = Codex.handle_message(%{"id" => 4, "result" => %{}}, state)
    refute Map.has_key?(state, :issue_notification_in_flight)

    Port.close(port)
  end

  test "serializes overlapping issue updates" do
    port = Port.open({:spawn, "cat"}, [:binary])

    assert {:noreply, state = %{issue_notification_in_flight: true}} =
             Codex.handle_message({:update, :issue_updated}, %{
               port: port,
               session_id: "thread",
               turn_id: "turn"
             })

    assert_receive {^port, {:data, _message}}

    assert {:noreply, state = %{pending: :issue_updated, issue_notification_in_flight: true}} =
             Codex.handle_message({:update, :issue_updated}, state)

    refute_receive {^port, {:data, _message}}

    assert {:noreply, state = %{issue_notification_in_flight: true}} =
             Codex.handle_message(%{"id" => 4, "result" => %{}}, state)

    refute Map.has_key?(state, :pending)
    assert_receive {^port, {:data, _message}}

    assert {:noreply, state = %{pending: :issue_updated}} =
             Codex.handle_message(%{"id" => 4, "error" => %{}}, state)

    refute Map.has_key?(state, :issue_notification_in_flight)
    refute Map.has_key?(state, :turn_id)

    Port.close(port)
  end

  test "defers a coalesced update until the next turn" do
    assert {:noreply, state = %{pending: :issue_updated}} =
             Codex.handle_message(%{"id" => 4, "result" => %{}}, %{
               pending: :issue_updated,
               issue_notification_in_flight: true
             })

    refute Map.has_key?(state, :issue_notification_in_flight)
  end
end
