defmodule AshAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_ai,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_json_api, "~> 1.4 and >= 1.4.20"},
      {:open_api_spex, "~> 3.0"},
      {:langchain, "~> 0.3"},
      {:igniter, "~> 0.5", optional: true}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp aliases do
    [
      "spark.formatter": "spark.formatter --extensions AshAi"
    ]
  end
end
