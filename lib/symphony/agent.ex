defmodule Symphony.Agent do
  alias Symphony.Planners
  use GenServer, restart: :temporary

  @type t :: %{
          agent: module(),
          issue: String.t(),
          planner: module(),
          port: port() | nil,
          prompt: String.t(),
          repo: Planners.repo(),
          session_id: String.t() | nil,
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
           workflow: self()
         }}
      )

    Map.put(issue, :agent, agent)
  end

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
    {:ok, state |> assign_port()}
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

  defp assign_port(%{port: nil, agent: agent} = state) do
    Map.put(state, :port, Port.open({:spawn, agent.command()}, [:binary, :exit_status]))
  end
end
