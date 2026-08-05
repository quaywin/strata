defmodule DBData.MixProject do
  use Mix.Project

  def project do
    [
      app: :db_data,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {DBData.Application, []}
    ]
  end

  def releases do
    [
      dbdata: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:postgrex, ">= 0.0.0"},
      {:myxql, ">= 0.0.0"},
      {:exqlite, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:ex_ratatui, git: "https://github.com/quaywin/ex_ratatui.git", branch: "main", override: true},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end
end

