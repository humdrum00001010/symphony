defmodule Symphony.Application do
  use Application

  alias Symphony.Workflow

  # TODO: needs to check if proper clients exist for each adapters, e.g. gh
  def start(_type, _args) do
    children =
      Application.get_env(:symphony, :path, "./workflows")
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        Supervisor.child_spec({Workflow, path: path}, id: path)
      end)

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
