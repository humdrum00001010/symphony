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
    for issue <- issues,
        !Planners.done?(issue, state.repo) do
      current
      |> Enum.find(&(&1.id == issue.id))
      |> update_agent(issue, state)
    end
    |> put_issues(state)
  end

  defp assign_pool(state) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Map.put(state, :supervisor, supervisor)
  end

  defp assign_version(state), do: Map.put(state, :version, 0)

  defp write(%{path: path, issues: issues} = state) do
    File.write!(
      path <> ".json",
      issues
      |> Enum.map(fn %{id: id} = issue ->
        %{id: id, session_id: Map.get(issue, :session_id)}
      end)
      |> JSON.encode!()
    )

    state
  end

  defp read(%{path: path} = state) do
    case File.read(path <> ".json") do
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
      states: config["states"] ++ config["terminal_states"],
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

  defp update_agent(nil, issue, state) do
    issue
    |> Map.put(:session_id, nil)
    |> Agent.start_agent(state)
  end

  defp update_agent(
         %{version: version, agent: agent, session_id: session_id} = current,
         %{version: version} = issue,
         state
       ) do
    case Process.alive?(agent) do
      true -> current
      false -> issue |> Map.put(:session_id, session_id) |> Agent.start_agent(state)
    end
  end

  defp update_agent(
         %{agent: agent, session_id: session_id},
         issue,
         state
       ) do
    case Process.alive?(agent) do
      true ->
        :ok = Agent.send_message(agent, issue)

        issue
        |> Map.put(:agent, agent)
        |> Map.put(:session_id, session_id)

      false ->
        issue
        |> Map.put(:session_id, session_id)
        |> Agent.start_agent(state)
    end
  end

  defp update_agent(%{session_id: session_id}, issue, state) do
    issue
    |> Map.put(:session_id, session_id)
    |> Agent.start_agent(state)
  end

  defp put_issues(issues, %{issues: issues} = state), do: state

  defp put_issues(issues, state) do
    for %{id: id, agent: agent} <- state.issues,
        Process.alive?(agent),
        Enum.all?(issues, &(&1.id != id)) do
      :ok = DynamicSupervisor.terminate_child(state.supervisor, agent)
    end

    state
    |> Map.put(:issues, issues)
    |> write()
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    pid = self()
    version = state.version + 1

    {:ok, _task} =
      Task.start(fn ->
        send(pid, {:update, version, fetch_issues(state)})
      end)

    {:noreply, Map.put(state, :version, version)}
  end

  def handle_info({:update, version, _result}, %{version: current} = state)
      when version < current do
    {:noreply, state}
  end

  def handle_info({:update, version, {:ok, issues}}, %{version: version} = state) do
    {:noreply, update_issues(state, issues)}
  end

  def handle_info({:update, version, {:error, reason}}, %{version: version} = state) do
    Logger.warning("Failed: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:update_session, issue, session_id}, _from, state) do
    {:reply, :ok, state |> assign_session(issue, session_id) |> write()}
  end

  defp assign_interval(state, interval), do: Map.put(state, :interval, interval)
end
