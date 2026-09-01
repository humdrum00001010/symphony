defmodule Symphony.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony,
      version: "0.1.0",
      elixir: "~> 1.20.4",
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Symphony.Application, []}
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.12.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
