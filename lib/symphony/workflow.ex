defmodule Symphony.Workflow do
  @moduledoc """
  Runs one workflow's periodic update loop.

  Updates run in unlinked tasks so external latency does not block or
  terminate the workflow process.
  """

  alias Symphony.Planners.Github

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     Keyword.get(opts, :path, "./WORKFLOW.md")
     |> get_workflow()
     |> assign_interval(Keyword.get(opts, :interval, 5_000)), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    send(self(), :tick)
    {:noreply, state}
  end

  def update_issues(%{issues: current} = state, issues) do
    Map.put(
      state,
      :issues,
      for issue <- issues do
        case Enum.find(current, &(&1.id == issue.id)) do
          %{version: version} = current when version == issue.version -> current
          _ -> issue
        end
      end
    )
  end

  def update(state, _tickets), do: state

  defp get_workflow(path) do
    ["", yaml, prompt] =
      File.read!(path)
      |> String.split(~r/^---[ \t]*\r?$/m, parts: 3)

    YamlElixir.read_from_string!(yaml)
    |> Map.put(:prompt, String.trim(prompt))
  end

  defp fetch_issues(%{"config" => %{"vendor" => "github"} = config}) do
    Github.fetch_issues(%{
      id: config["id"],
      states: config["states"]
    })
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    pid = self()

    {:ok, _task} =
      Task.start(fn ->
        send(pid, {:update, fetch_issues(state)})
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
