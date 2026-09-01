defmodule Symphony.Planners.Github do
  @behaviour Symphony.Planners

  @impl true
  def fetch_issues(%{id: repository, states: states})
      when is_binary(repository) and is_list(states) do
    states = Enum.map(states, &String.downcase/1)
    state = if length(states) == 1, do: hd(states), else: "all"

    {json, 0} =
      System.cmd(
        "gh",
        [
          "issue",
          "list",
          "--repo",
          repository,
          "--author",
          "@me",
          "--state",
          state,
          "--limit",
          "100000",
          "--json",
          "id,author,title,body,state,comments"
        ],
        stderr_to_stdout: true
      )

    {:ok,
     json
     |> JSON.decode!()
     |> Enum.filter(&(String.downcase(&1["state"]) in states))
     |> Enum.map(fn issue ->
       %{
         id: issue["id"],
         author: (issue["author"] || %{})["login"] || "",
         title: issue["title"],
         content: issue["body"] || "",
         state: String.downcase(issue["state"]),
         sub_issue: nil,
         comments:
           Enum.map(issue["comments"], fn comment ->
             %{
               id: comment["id"],
               author: (comment["author"] || %{})["login"] || "",
               content: comment["body"] || "",
               comments: []
             }
           end)
       }
     end)}
  end
end
