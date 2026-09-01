defmodule Symphony.Workflow do
  @moduledoc """
  Runs one workflow's periodic update loop.

  Updates run in unlinked tasks so external latency does not block or
  terminate the workflow process.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     opts
     |> Keyword.get(:path, "./WORKFLOW.md")
     |> get_workflow()
     |> assign_interval(Keyword.get(opts, :interval, 5_000)), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    send(self(), :tick)
    {:noreply, state}
  end

  # * Tickets would flow here. if matches state, does nothing
  def update(state, _tickets) do
    state
  end

  defp get_workflow(path) do
    # TODO: construct before / after, adapter, prompt of workflow.
    # TODO: here, we do configurations.
    # ? where should we free the completed ticket?
    %{path: path}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    pid = self()

    {:ok, _task} =
      Task.start(fn ->
        # TODO: Fetch updates through adapter, set by get_workflow()
        send(pid, {:update, {:ok, []}})
      end)

    {:noreply, state}
  end

  # ! Tickets have version
  def handle_info({:update, {:ok, tickets}}, state) do
    {:noreply, update(state, tickets)}
  end

  def handle_info({:update, {:error, reason}}, state) do
    Logger.warning("failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:update, _result}, state) do
    {:noreply, state}
  end

  defp assign_interval(state, interval), do: Map.put(state, :interval, interval)
end
