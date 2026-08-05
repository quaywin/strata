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

    case driver do
      d when d in [:sqlite, "sqlite"] -> "SELECT 1"
      d when d in [:postgres, "postgres", :postgresql] -> "SELECT 1"
      d when d in [:mysql, "mysql", :mariadb] -> "SELECT 1"
      _ -> "SELECT 1"
    end
  end

  defp connect_db(%ConnectionProfile{} = profile) do
    driver = normalize_driver(profile.driver)

    {host, port, tunnel_pid} = setup_network(profile, driver)

    case driver do
      :sqlite ->
        db_path = profile.database || ":memory:"

        case Exqlite.Sqlite3.open(db_path) do
          {:ok, conn} ->
            {:ok, %{driver: :sqlite, conn: conn, tunnel_pid: tunnel_pid, profile: profile}}

          {:error, reason} ->
            cleanup_tunnel(tunnel_pid)
            {:error, reason}
        end

      :postgres ->
        pg_opts =
          [
            hostname: host || "localhost",
            port: port || 5432,
            username: profile.username || "postgres",
            password: profile.password || "",
            database: profile.database || "postgres"
          ] ++ Map.to_list(profile.options || %{})

        case Postgrex.start_link(pg_opts) do
          {:ok, pid} ->
            {:ok, %{driver: :postgres, conn: pid, tunnel_pid: tunnel_pid, profile: profile}}

          {:error, reason} ->
            cleanup_tunnel(tunnel_pid)
            {:error, reason}
        end

      :mysql ->
        my_opts =
          [
            hostname: host || "localhost",
            port: port || 3306,
            username: profile.username || "root",
            password: profile.password || "",
            database: profile.database
          ] ++ Map.to_list(profile.options || %{})

        case MyXQL.start_link(my_opts) do
          {:ok, pid} ->
            {:ok, %{driver: :mysql, conn: pid, tunnel_pid: tunnel_pid, profile: profile}}

          {:error, reason} ->
            cleanup_tunnel(tunnel_pid)
            {:error, reason}
        end

      other ->
        cleanup_tunnel(tunnel_pid)
        {:error, "Unsupported driver: #{inspect(other)}"}
    end
  end

  defp setup_network(%ConnectionProfile{ssh_profile_id: ssh_id} = profile, driver)
       when is_binary(ssh_id) and ssh_id != "" do
    case SSHProfileStore.get_profile(ssh_id) do
      nil ->
        {profile.host, profile.port, nil}

      ssh_profile ->
        target_host = profile.host || "localhost"
        target_port = profile.port || default_port(driver)

        case SSHTunnel.connect(ssh_profile, target_host, target_port) do
          {:ok, local_port, tunnel_pid} ->
            {"127.0.0.1", local_port, tunnel_pid}

          {:error, _reason} ->
            {profile.host, profile.port, nil}
        end
    end
  end

  defp setup_network(profile, _driver) do
    {profile.host, profile.port, nil}
  end

  defp cleanup_tunnel(nil), do: :ok
  defp cleanup_tunnel(pid) when is_pid(pid), do: SSHTunnel.stop(pid)

  defp default_port(:postgres), do: 5432
  defp default_port(:mysql), do: 3306
  defp default_port(_), do: 0

  defp normalize_driver(driver) when is_atom(driver) do
    driver_str = Atom.to_string(driver) |> String.downcase()

    cond do
      driver_str in ["sqlite", "sqlite3"] -> :sqlite
      driver_str in ["postgres", "postgresql", "postgrex"] -> :postgres
      driver_str in ["mysql", "mariadb", "myxql"] -> :mysql
      true -> driver
    end
  end

  defp normalize_driver(driver) when is_binary(driver) do
    normalize_driver(String.to_atom(driver))
  end

  defp run_query(:sqlite, conn, sql, _params) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        {:ok, cols} = Exqlite.Sqlite3.columns(conn, stmt)
        {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        {:ok, %{columns: cols, rows: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_query(:postgres, conn, sql, params) do
    case Postgrex.query(conn, sql, params) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        {:ok, %{columns: cols, rows: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_query(:mysql, conn, sql, params) do
    case MyXQL.query(conn, sql, params) do
      {:ok, %MyXQL.Result{columns: cols, rows: rows}} ->
        {:ok, %{columns: cols, rows: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_db(:sqlite, conn) do
    Exqlite.Sqlite3.close(conn)
  end

  defp close_db(_driver, conn) when is_pid(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn)
    end
  rescue
    _ -> :ok
  end

  defp close_db(_driver, _conn), do: :ok
end
