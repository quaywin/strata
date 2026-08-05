defmodule Mix.Tasks.DbData do
  @moduledoc """
  Launches the interactive dbdata Database TUI interface.

  Usage:
      mix db_data
  """
  use Mix.Task

  @shortdoc "Launches the dbdata Database TUI"
  def run(args) do
    Mix.Task.run("app.start", args)
    DBData.CLI.main(args)
  end
end
