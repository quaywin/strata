defmodule Strata.CLI do
  @moduledoc """
  CLI entrypoint for handling flags and launching the interactive Strata TUI.
  """

  alias Strata.Updater

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
          :continue | :version | :help | {:update, keyword()} | {:error, [String.t()]}
  def parse_args(args) do
    cond do
      args == [] ->
        :continue

      args in [["--version"], ["-v"]] ->
        :version

      args in [["--help"], ["-h"]] ->
        :help

      args in [["update"], ["--update"]] ->
        {:update, [check_only: false]}

      args in [["update", "--check"], ["--check-update"], ["--update", "--check"]] ->
        {:update, [check_only: true]}

      true ->
        parse_update_with_version(args)
    end
  end

  defp parse_update_with_version(["update", "--version", ver]) when ver != "" do
    {:update, [check_only: false, version: ver]}
  end

  defp parse_update_with_version(["--update", "--version", ver]) when ver != "" do
    {:update, [check_only: false, version: ver]}
  end

  defp parse_update_with_version(args), do: {:error, args}

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

      {:update, opts} ->
        case run_update(opts) do
          :ok -> System.halt(0)
          {:error, _reason} -> System.halt(1)
        end

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

      {:update, opts} ->
        run_update(opts)

      :continue ->
        launch_tui()

      {:error, bad_args} ->
        IO.puts(:stderr, "Unrecognized arguments: #{Enum.join(bad_args, " ")}")
        print_help()
        {:error, {:invalid_args, bad_args}}
    end
  end

  @doc """
  Executes CLI update check / self-update workflow and prints progress to stdout/stderr.
  """
  @spec run_update(keyword()) :: :ok | {:error, String.t()}
  def run_update(opts \\ []) do
    check_only? = Keyword.get(opts, :check_only, false)
    updater_opts = Keyword.drop(opts, [:check_only])
    io = Keyword.get(opts, :io, :stdio)

    IO.puts(io, "Current version: v#{version()}")
    IO.puts(io, "Checking for updates from #{Updater.repo(updater_opts)}...")

    case Updater.check_for_update(updater_opts) do
      {:ok, %{status: :up_to_date} = info} ->
        IO.puts(io, "Strata is already up to date (v#{info.latest_version}).")
        :ok

      {:ok, %{status: :ahead} = info} ->
        IO.puts(
          io,
          "Current version (v#{info.current_version}) is ahead of latest release (v#{info.latest_version})."
        )

        :ok

      {:ok, %{status: :update_available} = info} when check_only? ->
        IO.puts(
          io,
          "Update available: v#{info.current_version} -> v#{info.latest_version} (#{info.tag_name})"
        )

        if info.release_url != "" do
          IO.puts(io, "Release notes: #{info.release_url}")
        end

        IO.puts(io, "Run `strata update` to install the latest release.")
        :ok

      {:ok, %{status: :update_available} = info} ->
        IO.puts(io, "Downloading Strata #{info.tag_name} (#{info.asset_name || info.target})...")

        case Updater.apply_update(info, updater_opts) do
          {:ok, result} ->
            IO.puts(
              io,
              "Successfully updated Strata to v#{result.version} at #{result.binary_path}!"
            )

            :ok

          {:error, reason} ->
            IO.puts(:stderr, "Update failed: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts(:stderr, "Update check failed: #{reason}")
        {:error, reason}
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
      strata update [options]

    Options:
      -h, --help            Show this help message
      -v, --version         Show version information
      --update              Check for and install the latest release
      --check-update        Check if a newer version is available

    Update Options:
      --check               Only check for updates without installing
      --version <tag>       Update to a specific release tag (e.g. v0.1.10)
    """)
  end

  @doc """
  Returns the default options passed to `Strata.UI.App.start_link/1` for TUI sessions.
  """
  @spec tui_start_opts() :: keyword()
  def tui_start_opts do
    [name: Strata.UI.App, terminal: true, mouse_capture: true, keyboard_enhancement: true]
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
