defmodule DBData.CLI do
  @moduledoc """
  CLI entrypoint for launching interactive TUI or Phoenix Web mode.
  """

  @doc """
  Main CLI entrypoint.
  """
  def main(args \\ []) do
    if "web" in args or "phx.server" in args or System.get_env("WEB") == "true" or System.get_env("PORT") != nil do
      Process.sleep(:infinity)
    else
      case DBData.UI.App.start_link(terminal: true, mouse_capture: true) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} ->
              :ok
          end

        {:error, {:already_started, pid}} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} ->
              :ok
          end

        {:error, reason} ->
          IO.puts(:stderr, "Failed to start DBData TUI: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
