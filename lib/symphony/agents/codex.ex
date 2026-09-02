defmodule Symphony.Agents.Codex do
  alias Symphony.Agent
  alias Symphony.Agents.Protocol
  alias Symphony.Planners

  @behaviour Protocol

  def command, do: "codex app-server 2>/dev/null"

  @impl true
  def handle_message(:wake, state) do
    {:noreply, state |> initialize()}
  end

  def handle_message({port, {:data, data}}, %{port: port} = state) do
    {messages, [buffer]} =
      state
      |> Map.get(:buffer, "")
      |> Kernel.<>(data)
      |> String.split("\n")
      |> Enum.split(-1)

    messages
    |> Enum.map(&parse_message/1)
    |> Enum.each(&send(self(), &1))

    {:noreply, Map.put(state, :buffer, buffer)}
  end

  def handle_message(%{"id" => 0, "result" => _result}, state) do
    {:noreply, state |> start_session()}
  end

  def handle_message(
        %{"id" => 1, "result" => %{"thread" => %{"id" => session_id}}},
        %{prompt: prompt} = state
      ) do
    {:ok, state} = Protocol.put_session(state, session_id)

    {:noreply, state |> start_turn([%{type: "text", text: prompt}])}
  end

  def handle_message(
        %{"id" => 2, "result" => %{"thread" => %{"id" => session_id}}},
        %{session_id: session_id} = state
      ) do
    {:noreply,
     state
     |> start_turn([%{type: "text", text: "Continue."}])}
  end

  def handle_message(
        %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id}}},
        %{pending: pending} = state
      ) do
    handle_message(
      {:update, pending},
      state |> Map.delete(:pending) |> Map.put(:turn_id, turn_id)
    )
  end

  def handle_message(%{"id" => 3, "result" => %{"turn" => %{"id" => turn_id}}}, state) do
    {:noreply, Map.put(state, :turn_id, turn_id)}
  end

  def handle_message(
        {:update, diff},
        %{session_id: session_id, turn_id: turn_id} = state
      ) do
    {:noreply,
     Agent.send_message(state, %{
       method: "turn/steer",
       id: 4,
       params: %{
         threadId: session_id,
         expectedTurnId: turn_id,
         input: [%{type: "text", text: JSON.encode!(diff)}]
       }
     })}
  end

  def handle_message({:update, issue}, state) do
    {:noreply, Map.put(state, :pending, issue)}
  end

  def handle_message(%{"id" => 2, "error" => _}, state) do
    {:ok, state} = Protocol.put_session(state, nil)
    {:noreply, state |> start_session()}
  end

  def handle_message(%{"method" => "turn/completed"}, state) do
    if Planners.completed?(state.planner, state) do
      {:stop, :normal, state}
    else
      {:noreply,
       state
       |> start_turn([
         %{type: "text", text: "I think I said enough."}
       ])}
    end
  end

  def handle_message(%{"error" => error}, state) do
    {:stop, {__MODULE__, error}, state}
  end

  def handle_message(_message, state) do
    {:noreply, state}
  end

  defp initialize(state) do
    state
    |> Agent.send_message(%{
      method: "initialize",
      id: 0,
      params: %{clientInfo: %{name: "symphony", version: "0.1.0"}}
    })
    |> Agent.send_message(%{method: "initialized"})
  end

  defp start_session(%{session_id: nil} = state) do
    Agent.send_message(state, %{method: "thread/start", id: 1, params: %{}})
  end

  defp start_session(%{session_id: session_id} = state) do
    Agent.send_message(state, %{
      method: "thread/resume",
      id: 2,
      params: %{threadId: session_id, excludeTurns: true}
    })
  end

  defp start_turn(%{session_id: session_id} = state, input) do
    Agent.send_message(Map.delete(state, :turn_id), %{
      method: "turn/start",
      id: 3,
      params: %{
        threadId: session_id,
        input: input,
        approvalPolicy: "never",
        sandboxPolicy: %{type: "dangerFullAccess"}
      }
    })
  end

  defp parse_message(data), do: JSON.decode!(data)
end
