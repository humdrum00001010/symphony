defmodule Symphony.AgentTest do
  use ExUnit.Case, async: false

  alias Symphony.Agent

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
    path = System.fetch_env!("PATH")

    File.mkdir!(directory)

    File.write!(
      codex,
      ~S"""
      #!/bin/sh
      printf 'run\n' >> "$CODEX_RUNS"

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

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("CODEX_RUNS")
      System.delete_env("CODEX_MESSAGES")
      System.delete_env("CODEX_TURNS")
      System.delete_env("GH_CHECKS")
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
        repo: %{id: "owner/repo", states: ["Open"], terminal_states: ["CLOSED"]}
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
    assert File.read!(messages) =~ "\"method\":\"thread/resume\""
    assert File.read!(messages) =~ "\"method\":\"thread/start\""
    assert File.read!(messages) =~ "\"approvalPolicy\":\"never\""
    assert File.read!(messages) =~ "\"type\":\"dangerFullAccess\""
    assert File.read!(messages) |> String.split("\"method\":\"turn/start\"") |> length() == 3
    assert File.read!(messages) |> String.split("Fix the issue") |> length() == 2
    assert File.read!(checks) == "2"
  end
end
