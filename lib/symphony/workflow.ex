defmodule Symphony.Workflow do
  @moduledoc """
  Runs one workflow's periodic update loop.

  Updates run in unlinked tasks so external latency does not block or
  terminate the workflow process.
  """

  alias Symphony.Agents.Codex
  alias Symphony.Agent
  alias Symphony.Planners.Github
  alias Symphony.Planners

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def update_session(workflow, issue, session_id) do
    GenServer.call(workflow, {:update_session, issue, session_id})
  end

  @impl true
  def init(opts) do
    {:ok,
     Keyword.get(opts, :path, "./WORKFLOW.md")
     |> get_workflow()
     |> assign_interval(Keyword.get(opts, :interval, 5_000))
     |> resolve_agent()
     |> resolve_planner()
     |> read()
     |> assign_pool()
     |> assign_version(), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    send(self(), :tick)
    {:noreply, state}
  end

  def update_issues(%{issues: current} = state, issues) do
    updated =
      for issue <- issues, !Planners.terminal?(issue, state.repo) do
        if Planners.done?(issue) do
          Enum.find(current, Map.put(issue, :session_id, nil), &(&1.id == issue.id))
        else
          Enum.find(current, &(&1.id == issue.id)) |> Agent.update(issue, state)
        end
      end

    if updated == current do
      state
    else
      for %{id: id} = issue <- current,
          Enum.all?(updated, &(&1.id != id)) do
        :ok = Agent.stop_agent(issue)
        :ok = Agent.terminate_work(issue, state)
      end

      state
      |> Map.put(:issues, updated)
      |> write()
    end
  end

  defp assign_pool(state) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Map.put(state, :supervisor, supervisor)
  end

  defp assign_version(state), do: Map.put(state, :version, 0)

  defp write(%{path: path, issues: issues} = state) do
    File.write!(
      Path.rootname(path) <> ".json",
      issues
      |> Enum.map(fn %{id: id} = issue ->
        %{id: id, session_id: Map.get(issue, :session_id)}
      end)
      |> JSON.encode!()
    )

    state
  end

  defp read(%{path: path} = state) do
    case File.read(Path.rootname(path) <> ".json") do
      {:ok, json} ->
        Map.put(
          state,
          :issues,
          json
          |> JSON.decode!()
          |> Enum.map(fn %{"id" => id, "session_id" => session_id} ->
            %{id: id, session_id: session_id}
          end)
        )

      {:error, :enoent} ->
        Map.put(state, :issues, [])
    end
  end

  defp get_workflow(path) do
    ["", yaml, prompt] =
      File.read!(path)
      |> String.split(~r/^---[ \t]*\r?$/m, parts: 3)

    YamlElixir.read_from_string!(yaml)
    |> Map.put(:path, path)
    |> Map.put(:prompt, String.trim(prompt))
  end

  defp resolve_agent(state) do
    agent =
      case agent = state["agent"]["vendor"] do
        "codex" -> Codex
        _ -> raise "Unsupported agent: #{agent}. Check if lowercase"
      end

    Map.put(state, :agent, agent)
  end

  defp resolve_planner(%{"config" => %{"vendor" => "github"} = config} = state) do
    state
    |> Map.put(:planner, Github)
    |> Map.put(:repo, %{
      id: config["id"],
      states: config["states"],
      terminal_states: config["terminal_states"]
    })
  end

  defp fetch_issues(%{planner: planner, repo: repo}), do: planner.fetch_issues(repo)

  defp assign_session(state, issue, session_id) do
    Map.update!(state, :issues, fn issues ->
      Enum.map(issues, fn
        %{id: ^issue} = current -> Map.put(current, :session_id, session_id)
        current -> current
      end)
    end)
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    pid = self()
    version = System.unique_integer([:positive, :monotonic])

    {:ok, _task} =
      Task.start(fn ->
        send(pid, {:update, version, fetch_issues(state)})
      end)

    {:noreply, state}
  end

  def handle_info({:update, version, _result}, %{version: current} = state)
      when version < current do
    {:noreply, state}
  end

  def handle_info({:update, version, {:ok, issues}}, state) do
    {:noreply, state |> Map.put(:version, version) |> update_issues(issues)}
  end

  def handle_info({:update, _version, {:error, reason}}, state) do
    Logger.warning("Failed: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:update_session, issue, session_id}, _from, state) do
    {:reply, :ok, state |> assign_session(issue, session_id) |> write()}
  end

  defp assign_interval(state, interval), do: Map.put(state, :interval, interval)
end
