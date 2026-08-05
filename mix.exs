defmodule DBData.MixProject do
  use Mix.Project

  def project do
    [
      app: :db_data,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {DBData.Application, []}
    ]
  end

  defp deps do
    [
      {:postgrex, ">= 0.0.0"},
      {:myxql, ">= 0.0.0"},
      {:exqlite, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end
end
