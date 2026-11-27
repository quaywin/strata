defmodule Strata.BurritoTUI do
  @moduledoc """
  Burrito launcher wrapper for `ExRatatui.Burrito`.

  `ExRatatui.Burrito` invokes `mod.start_link([])` with an empty option list,
  leaving `:mouse_capture` disabled (`false` by default in `ExRatatui.Server`).
  This module forwards `Strata.CLI.tui_start_opts/0` to `Strata.UI.App.start_link/1`
  so standalone Burrito builds enable mouse clicks and horizontal/vertical scrolling.
  """

  @doc """
  Starts `Strata.UI.App` with Strata's TUI startup options merged with `opts`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Strata.CLI.tui_start_opts()
    |> Keyword.merge(opts)
    |> Strata.UI.App.start_link()
  end
end
