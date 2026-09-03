defmodule Symphony.Agent do
  alias Symphony.Planners
  use GenServer, restart: :temporary

  @type t :: %{
          agent: module(),
          issue: String.t(),
          planner: module(),
          port: port() | nil,
          prompt: String.t(),
          group: pid(),
          repo: Planners.repo(),
          session_id: String.t() | nil,
          workspace: String.t(),
          workflow: pid()
        }

  @type owner :: %{
          agent: module(),
          planner: module(),
          prompt: String.t(),
          repo: Planners.repo(),
          supervisor: pid()
        }

  @spec start_agent(map(), owner()) :: map()
  def start_agent(issue, owner) do
    {:ok, agent} =
      DynamicSupervisor.start_child(
        owner.supervisor,
        {__MODULE__,
         %{
           agent: owner.agent,
           issue: issue.id,
           planner: owner.planner,
           port: nil,
           prompt: owner.prompt <> "\n\n" <> JSON.encode!(issue),
           repo: owner.repo,
           session_id: Map.get(issue, :session_id),
           workspace:
             owner["config"]["workspace"]
             |> Path.expand()
             |> Path.join(owner.repo.id)
             |> Path.join(issue.id),
           workflow: self()
         }}
      )

    assign_agent(issue, agent)
  end

  @spec assign_agent(map(), pid() | map()) :: map()
  def assign_agent(issue, agent) when is_pid(agent) do
    assign_agent(issue, %{agent: agent, group: GenServer.call(agent, :group)})
  end

  def assign_agent(issue, %{agent: agent, group: group}) do
    issue
    |> Map.put(:agent, agent)
    |> Map.put(:group, group)
  end

  @spec stop_agent(map()) :: :ok
  def stop_agent(%{agent: agent, group: group}) do
    reference = Process.monitor(group)

    if Process.alive?(agent) do
      GenServer.stop(agent, :normal, :infinity)
    end

    receive do
      {:DOWN, ^reference, :process, ^group, :normal} -> :ok
      {:DOWN, ^reference, :process, ^group, reason} -> exit(reason)
    end
  end

  def stop_agent(_issue), do: :ok

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_message(%{port: port} = state, message) do
    true = Port.command(port, JSON.encode!(message) <> "\n")
    state
  end

  def send_message(agent, message) do
    GenServer.cast(agent, {:update, message})
  end

  @impl true
  def init(state) do
    send(self(), :wake)
    {:ok, state |> assign_port() |> assign_group()}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if Planners.completed?(state.planner, state) do
      {:stop, :normal, state}
    else
      {:stop, {:exit_status, status}, state}
    end
  end

  def handle_info(message, %{agent: agent} = state) do
    agent.handle_message(message, state)
  end

  @impl true
  def handle_cast(message, %{agent: agent} = state) do
    agent.handle_message(message, state)
  end

  @impl true
  def handle_call(:group, _from, state), do: {:reply, state.group, state}

  defp assign_port(%{port: nil, agent: agent, workspace: workspace} = state) do
    Map.put(
      state,
      :port,
      Port.open({:spawn, agent.command()}, [:binary, :exit_status, {:cd, workspace}])
    )
  end

  defp assign_group(%{port: port} = state) do
    owner = self()
    {:os_pid, pid} = Port.info(port, :os_pid)
    Map.put(state, :group, spawn(fn -> reap(owner, pid) end))
  end

  defp reap(owner, pid) do
    reference = Process.monitor(owner)

    receive do
      {:DOWN, ^reference, :process, ^owner, _reason} -> kill_group(pid)
    end
  end

  defp kill_group(pid) do
    case System.cmd("sh", ["-c", "kill -KILL -#{pid} 2>/dev/null"]) do
      {_, 0} ->
        await_group(pid)

      {_, 1} ->
        assert_group_gone(pid)
    end
  end

  defp await_group(pid) do
    case System.cmd("pgrep", ["-g", Integer.to_string(pid)]) do
      {_, 0} ->
        Process.sleep(1)
        await_group(pid)

      {_, 1} ->
        :ok
    end
  end

  defp assert_group_gone(pid) do
    case System.cmd("pgrep", ["-g", Integer.to_string(pid)]) do
      {_, 0} -> exit({:group_kill_failed, pid})
      {_, 1} -> :ok
    end
  end
end
