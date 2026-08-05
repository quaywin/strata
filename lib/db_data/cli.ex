defmodule DBData.CLI do
  @moduledoc """
  CLI entrypoint for launching the interactive Terminal User Interface (TUI) powered by ExRatatui.
  """

  @doc """
  Main CLI entrypoint. Launches full-screen interactive Ratatui TUI canvas.
  """
  def main(_args \\ []) do
    ExRatatui.run(DBData.UI.App, [terminal: true, mouse_capture: true])
  end
end
