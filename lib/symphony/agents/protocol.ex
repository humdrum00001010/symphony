defmodule Symphony.Agents.Protocol do
  # An abstraction on CLI of agents, codex, claude.

  alias Symphony.Workflow

  @callback handle_message(message :: any(), state :: map()) ::
              {:noreply, map()} | {:stop, term(), map()}

  @spec put_session(state :: map(), session_id :: any()) :: {:ok, map()} | {:error, any()}
  def put_session(%{workflow: workflow, issue: issue} = state, session_id) do
    :ok = Workflow.update_session(workflow, issue, session_id)
    {:ok, Map.put(state, :session_id, session_id)}
  end
end
