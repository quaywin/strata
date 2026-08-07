defmodule Strata.CLI do
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
      # Kill any stale GenServer instance to guarantee fresh code reload
      if pid = Process.whereis(Strata.UI.App) do
        try do
          GenServer.stop(pid, :normal)
        catch
          _, _ -> Process.exit(pid, :kill)
        end

        Process.sleep(50)
      end

      case Strata.UI.App.start_link(terminal: true, mouse_capture: true) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} ->
              :ok
          end

        {:error, {:already_started, pid}} ->
          try do
            GenServer.stop(pid, :normal)
          catch
            _, _ -> Process.exit(pid, :kill)
          end
          Process.sleep(50)
          main(args)

        {:error, reason} ->
          IO.puts(:stderr, "Failed to start Strata TUI: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
