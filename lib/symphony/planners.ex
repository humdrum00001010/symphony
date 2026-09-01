defmodule Symphony.Planners do
  @type t :: %{
          id: String.t(),
          states: [String.t()]
        }
  @type issue :: %{
          id: String.t(),
          author: String.t(),
          title: String.t(),
          content: String.t(),
          state: String.t(),
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
  @callback fetch_issues(params :: t()) :: {:ok, [issue()]} | {:error, any()}
end
