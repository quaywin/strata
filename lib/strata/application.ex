defmodule Strata.Application do
  use Application

  @env Application.compile_env(:strata, :env, :prod)

  @impl true
  def start(_type, _args) do
    args = cli_args()

    if @env != :test and running_in_burrito?() do
      Strata.CLI.handle_args(args)
    end

    if @env != :test do
      setup_file_logging()

      if tui_terminal?() do
        suppress_console_logging()
        install_signal_handler()
      end
    end

    base_children = [
      {Phoenix.PubSub, name: Strata.PubSub},
      Strata.SSHProfileStore,
      Strata.ConfigStore,
      Strata.DataStore,
      {Registry, keys: :unique, name: Strata.ConnectionRegistry},
      Strata.ConnectionSupervisor
    ]

    children =
      if @env != :test and running_in_burrito?() and tui_terminal?() do
        burrito_child = %{
          id: Strata.BurritoTUI,
          start:
            {ExRatatui.Burrito, :start_link,
             [Strata.BurritoTUI, args, [name: "strata", version: Strata.CLI.version()]]},
          restart: :transient
        }

        base_children ++ [burrito_child]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: Strata.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp cli_args do
    if running_in_burrito?() do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end

  defp running_in_burrito? do
    System.get_env("__BURRITO") != nil
  end

  defp setup_file_logging do
    log_dir = Path.expand("~/.strata")
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "strata.log")

    try do
      :logger.add_handler(:strata_file_log, :logger_std_h, %{
        config: %{type: :file, file: String.to_charlist(log_file)},
        level: :info
      })
    catch
      _, _ -> :ok
    end
  end

  defp suppress_console_logging do
    Logger.configure(backends: [])
    _ = :logger.remove_handler(:default)
    :logger.set_primary_config(:level, :info)
  catch
    _, _ -> :ok
  end

  defp install_signal_handler do
    :os.set_signal(:sighup, :handle)
    :os.set_signal(:sigterm, :handle)
    :gen_event.add_handler(:erl_signal_server, Strata.SignalHandler, [])
  catch
    _, _ -> :ok
  end

  defp tui_terminal? do
    cond do
      System.get_env("STRATA_TUI") == "false" -> false
      Code.ensure_loaded?(IEx) && IEx.started?() -> false
      System.get_env("TERM") not in [nil, "", "dumb"] -> true
      match?({:ok, _}, :io.columns()) -> true
      true -> false
    end
  end
end
