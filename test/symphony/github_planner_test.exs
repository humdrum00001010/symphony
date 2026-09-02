defmodule Symphony.GithubPlannerTest do
  use ExUnit.Case, async: false

  alias Symphony.Planners.Github

  test "fetches my issues and comments through gh" do
    directory =
      Path.join(System.tmp_dir!(), "symphony-gh-#{System.unique_integer([:positive])}")

    gh = Path.join(directory, "gh")
    arguments = Path.join(directory, "arguments")
    path = System.fetch_env!("PATH")

    File.mkdir!(directory)

    File.write!(
      gh,
      ~S|#!/bin/sh
printf '%s\n' "$*" > "$GH_ARGS_LOG"
printf '%s' '[{"number":1,"author":{"login":"me"},"title":"Fix","body":"Body","state":"OPEN","updatedAt":"2026-01-02T00:00:00Z","comments":[{"id":"comment-1","author":{"login":"you"},"body":"Comment","createdAt":"2026-01-01T00:00:00Z"}]}]'
|
    )

    File.chmod!(gh, 0o755)
    System.put_env("PATH", directory <> ":" <> path)
    System.put_env("GH_ARGS_LOG", arguments)

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("GH_ARGS_LOG")
      File.rm_rf!(directory)
    end)

    assert {:ok,
            [
              %{
                id: "1",
                author: "me",
                title: "Fix",
                content: "Body",
                state: "OPEN",
                version: "2026-01-02T00:00:00Z",
                sub_issue: nil,
                comments: [
                  %{id: "comment-1", author: "you", content: "Comment", comments: []}
                ]
              }
            ]} =
             Github.fetch_issues(%{
               id: "owner/repo",
               states: ["OPEN", "CLOSED"],
               terminal_states: ["CLOSED"]
             })

    assert File.read!(arguments) =~
             "issue list --repo owner/repo --author @me --state all"
  end
end
