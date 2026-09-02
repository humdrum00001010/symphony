defmodule Symphony.Planners do
  @type repo :: %{
          id: String.t(),
          states: [String.t()],
          terminal_states: [String.t()]
        }
  @type issue :: %{
          id: String.t(),
          author: String.t(),
          title: String.t(),
          content: String.t(),
          state: String.t(),
          version: String.t(),
          # * not used frequently
          sub_issue: issue() | nil,
          comments: [article()]
        }
  # * Some vendors won't allow recursive comment structure
  @type article :: %{
          id: String.t(),
          author: String.t(),
          content: String.t(),
          comments: [article()]
        }
  @callback fetch_issues(params :: repo()) :: {:ok, [issue()]} | {:error, any()}
  @callback fetch_issue(params :: repo(), issue_id :: String.t()) ::
              {:ok, issue()} | {:error, any()}

  def done?(%{comments: []}), do: false

  def done?(%{comments: comments}) do
    comments
    |> List.last()
    |> Map.get(:content, "")
    |> String.ends_with?("∎")
  end

  def terminal?(%{state: state}, %{terminal_states: terminal_states}),
    do: state in terminal_states

  def completed?(planner, %{repo: params, issue: issue_id}) do
    case planner.fetch_issue(params, issue_id) do
      {:ok, issue} ->
        done?(issue)

      {:error, _} ->
        false
    end
  end
end
