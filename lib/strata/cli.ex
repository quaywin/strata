defmodule Strata.CLI do
  @moduledoc """
  CLI entrypoint for handling flags and launching the interactive Strata TUI.
  """

  @doc """
  Returns the current Strata application version string.
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:strata, :vsn) do
      nil -> "0.1.0"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Parses CLI arguments into an action tuple.
  """
  @spec parse_args([String.t()]) ::
          :continue | :version | :help | {:error, [String.t()]}
  def parse_args(args) do
    cond do
      args == [] -> :continue
      args in [["--version"], ["-v"]] -> :version
      args in [["--help"], ["-h"]] -> :help
      true -> {:error, args}
    end
  end

  @doc """
  Handles CLI arguments for standalone Burrito execution.
  Returns `:continue` when the TUI should start, otherwise halts the VM.
  """
  @spec handle_args([String.t()]) :: :continue
  def handle_args(args) do
    case parse_args(args) do
      :continue ->
        :continue

      :version ->
        ensure_native_loaded!()
        print_version()
        System.halt(0)

      :help ->
        print_help()
        System.halt(0)

      {:error, bad_args} ->
        IO.puts(:stderr, "Unrecognized arguments: #{Enum.join(bad_args, " ")}")
        print_help()
        System.halt(1)
    end
  end

  @doc """
  Main CLI entrypoint used by `mix strata`.
  """
  def main(args \\ []) do
    case parse_args(args) do
      :version ->
        print_version()
        :ok

      :help ->
        print_help()
        :ok

      :continue ->
        launch_tui()

      {:error, bad_args} ->
        IO.puts(:stderr, "Unrecognized arguments: #{Enum.join(bad_args, " ")}")
        print_help()
        {:error, {:invalid_args, bad_args}}
    end
  end

  @doc """
  Prints the current version to stdout.
  """
  def print_version do
    IO.puts("Strata v#{version()}")
  end

  @doc """
  Prints CLI usage information to stdout.
  """
  def print_help do
    IO.puts("""
    Strata - Modern Terminal Database Manager

    Usage:
      strata [options]

    Options:
      -h, --help      Show this help message
      -v, --version   Show version information
    """)
  end

  @doc """
  Returns the default options passed to `Strata.UI.App.start_link/1` for TUI sessions.
  """
  @spec tui_start_opts() :: keyword()
  def tui_start_opts do
    [name: Strata.UI.App, terminal: true, mouse_capture: true]
  end

  defp ensure_native_loaded! do
    if Code.ensure_loaded?(ExRatatui.Native) do
      :ok = ExRatatui.Native.ensure_loaded()
    end
  end

  defp launch_tui do
    # Kill any stale GenServer instance to guarantee fresh code reload
    if pid = Process.whereis(Strata.UI.App) do
      try do
        GenServer.stop(pid, :normal)
      catch
        _, _ -> Process.exit(pid, :kill)
      end

      Process.sleep(50)
    end

    case Strata.UI.App.start_link(tui_start_opts()) do
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
        launch_tui()

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start Strata TUI: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
