defmodule Strata.Web.AppLive do
  use PhoenixExRatatui.LiveView

  def tui_mount(opts) do
    if loaded?(), do: Strata.UI.App.mount(opts), else: {:ok, %{}}
  end

  def tui_render(state, frame) do
    if loaded?(), do: Strata.UI.App.render(state, frame), else: []
  end

  def tui_handle_event(event, state) do
    if loaded?(), do: Strata.UI.App.handle_event(event, state), else: {:noreply, state}
  end

  def tui_handle_info(msg, state) do
    if loaded?(), do: Strata.UI.App.handle_info(msg, state), else: {:noreply, state}
  end

  def tui_terminate(reason, state) do
    if loaded?(), do: Strata.UI.App.terminate(reason, state), else: :ok
  end

  defp loaded? do
    match?({:module, _}, Code.ensure_loaded(Strata.UI.App))
  end
end
