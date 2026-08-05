defmodule Mix.Tasks.Strata do
  @moduledoc """
  Launches the interactive strata Database TUI interface.

  Usage:
      mix strata
  """
  use Mix.Task

  @shortdoc "Launches the strata Database TUI"
  def run(args) do
    Mix.Task.run("app.start", args)
    Strata.CLI.main(args)
  end
end
