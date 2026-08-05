defmodule DBData.ConnectionWorker do
  @moduledoc """
  GenServer handling database connections for Postgres, MySQL, and SQLite.
  Supports SSH tunneling via DBData.SSHTunnel.
  """
  use GenServer

  alias DBData.ConnectionProfile
  alias DBData.SSHProfileStore
  alias DBData.SSHTunnel

  # Client API

  @doc """
  Starts a ConnectionWorker with a given ConnectionProfile.
  Usage:
      ConnectionWorker.start_link(profile)
      ConnectionWorker.start_link(profile, opts)
  """
  def start_link(%ConnectionProfile{} = profile, opts \\ []) do
    GenServer.start_link(__MODULE__, profile, opts)
  end

  @doc """
  Executes a SQL query on the connection worker process.
  Returns `{:ok, %{columns: [String.t()], rows: [list()]}}` or `{:error, term()}`.
  """
  def execute_query(worker, sql, params \\ []) when is_binary(sql) do
    GenServer.call(worker, {:execute_query, sql, params}, 30_000)
  end

  @doc """
  Tests connection for either a ConnectionProfile struct or a running worker PID.
  Returns `:ok` or `{:error, term()}`.
  """
  def test_connection(%ConnectionProfile{} = profile) do
    case start_link(profile) do
      {:ok, pid} ->
        res = test_connection(pid)
        stop(pid)
        res

      {:error, reason} ->
        {:error, reason}
    end
  end

  def test_connection(pid) when is_pid(pid) or is_atom(pid) do
    case execute_query(pid, probe_query(pid)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(pid) when is_pid(pid) or is_atom(pid) do
    GenServer.stop(pid)
  end

  # Server Callbacks

  @impl true
  def init(%ConnectionProfile{} = profile) do
    case connect_db(profile) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute_query, sql, params}, _from, state) do
    case run_query(state.driver, state.conn, sql, params) do
      {:ok, res} -> {:reply, {:ok, res}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_driver, _from, state) do
    {:reply, state.driver, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_db(state.driver, state.conn)

    if Map.get(state, :tunnel_pid) do
      SSHTunnel.stop(state.tunnel_pid)
    end

    :ok
  end

  # Private Helpers

  defp probe_query(pid) do
    driver =
      try do
        GenServer.call(pid, :get_driver)
      catch
        _, _ -> :sqlite
      end

    adapter = DBData.Adapter.for_driver(driver)
    adapter.probe_query()
  rescue
    _ -> "SELECT 1"
  end

  defp connect_db(%ConnectionProfile{} = profile) do
    driver = DBData.Adapter.normalize_driver(profile.driver)

    {host, port, tunnel_pid} = setup_network(profile, driver)

    try do
      adapter = DBData.Adapter.for_driver(driver)

      case adapter.connect(profile, host, port) do
        {:ok, conn} ->
          {:ok, %{driver: driver, adapter: adapter, conn: conn, tunnel_pid: tunnel_pid, profile: profile}}

        {:error, reason} ->
          cleanup_tunnel(tunnel_pid)
          {:error, reason}
      end
    rescue
      e ->
        cleanup_tunnel(tunnel_pid)
        {:error, Exception.message(e)}
    end
  end

  defp setup_network(%ConnectionProfile{ssh_profile_id: ssh_id} = profile, driver)
       when is_binary(ssh_id) and ssh_id != "" do
    try do
      case SSHProfileStore.get_profile(ssh_id) do
        nil ->
          {profile.host, profile.port, nil}

        ssh_profile ->
          target_host = profile.host || "localhost"
          target_port = profile.port || DBData.Adapter.default_port(driver)

          case SSHTunnel.connect(ssh_profile, target_host, target_port) do
            {:ok, local_port, tunnel_pid} ->
              {"127.0.0.1", local_port, tunnel_pid}

            {:error, _reason} ->
              {profile.host, profile.port, nil}
          end
      end
    rescue
      _ -> {profile.host, profile.port, nil}
    catch
      _, _ -> {profile.host, profile.port, nil}
    end
  end

  defp setup_network(profile, _driver) do
    {profile.host, profile.port, nil}
  end

  defp cleanup_tunnel(nil), do: :ok
  defp cleanup_tunnel(pid) when is_pid(pid), do: SSHTunnel.stop(pid)

  defp run_query(driver, conn, sql, params) do
    adapter = DBData.Adapter.for_driver(driver)
    adapter.execute_query(conn, sql, params)
  end

  defp close_db(driver, conn) do
    adapter = DBData.Adapter.for_driver(driver)
    adapter.close(conn)
  rescue
    _ -> :ok
  end
end
