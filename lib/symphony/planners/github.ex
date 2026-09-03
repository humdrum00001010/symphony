defmodule Symphony.Planners.Github do
  @behaviour Symphony.Planners

  @impl true
  # * github's issue doesn't have that rich states
  def fetch_issues(%{id: repository, states: states}) do
    case System.cmd(
           "gh",
           [
             "issue",
             "list",
             "--repo",
             repository,
             "--author",
             "@me",
             "--state",
             "open",
             "--limit",
             "100000",
             "--json",
             "number,author,title,body,state,updatedAt,comments"
           ]
         ) do
      {json, 0} ->
        {:ok,
         json
         |> JSON.decode!()
         |> Enum.map(&from_json/1)
         |> Enum.filter(&(&1.state in states))}

      {_output, status} ->
        {:error, status}
    end
  end

  @impl true
  def fetch_issue(%{id: repository}, issue_id) do
    {json, 0} =
      System.cmd(
        "gh",
        [
          "issue",
          "view",
          issue_id,
          "--repo",
          repository,
          "--json",
          "number,author,title,body,state,updatedAt,comments"
        ]
      )

    {:ok, json |> JSON.decode!() |> from_json()}
  end

  defp from_json(issue) do
    %{
      id: to_string(issue["number"]),
      author: issue["author"]["login"],
      title: issue["title"],
      content: issue["body"],
      state: issue["state"],
      version: issue["updatedAt"],
      sub_issue: nil,
      comments:
        issue["comments"]
        |> Enum.sort_by(& &1["createdAt"])
        |> Enum.map(fn comment ->
          %{
            id: comment["id"],
            author: comment["author"]["login"],
            content: comment["body"],
            comments: []
          }
        end)
    }
  end
end
