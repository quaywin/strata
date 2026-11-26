defmodule Strata.ConnectionWorker do
  @moduledoc """
  GenServer handling persistent database connections for Postgres, MySQL, and SQLite.
  Supports SSH tunneling via Strata.SSHTunnel and supervised lifecycle via Strata.ConnectionSupervisor.
  """
  use GenServer, restart: :temporary

  alias Strata.ConnectionProfile
  alias Strata.ConnectionSupervisor
  alias Strata.SSHProfileStore
  alias Strata.SSHTunnel

  # Client API

  @doc """
  Starts a ConnectionWorker with a given ConnectionProfile or `{profile, opts}` tuple.
  """
  def start_link({%ConnectionProfile{} = profile, opts}) when is_list(opts) do
    {name_opt, worker_opts} = Keyword.pop(opts, :name)

    if name_opt do
      GenServer.start_link(__MODULE__, {profile, worker_opts}, name: name_opt)
    else
      GenServer.start_link(__MODULE__, {profile, worker_opts})
    end
  end

  def start_link(%ConnectionProfile{} = profile, opts \\ []) do
    start_link({profile, opts})
  end

  @doc """
  Executes a SQL query using the supervised persistent ConnectionWorker for `profile`.
  Falls back to a transient worker if `ConnectionSupervisor` is not started.
  """
  def execute_query_for_profile(%ConnectionProfile{} = profile, sql, params \\ [])
      when is_binary(sql) do
    if Process.whereis(ConnectionSupervisor) && Process.whereis(Strata.ConnectionRegistry) do
      case ConnectionSupervisor.get_or_start_worker(profile) do
        {:ok, pid} ->
          execute_query(pid, sql, params)

        {:error, reason} ->
          {:error, reason}
      end
    else
      with_transient_worker(profile, fn pid -> execute_query(pid, sql, params) end)
    end
  end

  @doc """
  Runs `fun.(worker_pid)` against a persistent supervised ConnectionWorker for `profile`
  (or a transient worker when the supervisor is unavailable).
  """
  def with_worker(%ConnectionProfile{} = profile, fun) when is_function(fun, 1) do
    if Process.whereis(ConnectionSupervisor) && Process.whereis(Strata.ConnectionRegistry) do
      case ConnectionSupervisor.get_or_start_worker(profile) do
        {:ok, pid} -> {:ok, fun.(pid)}
        {:error, reason} -> {:error, reason}
      end
    else
      case start_link(profile) do
        {:ok, pid} ->
          try do
            {:ok, fun.(pid)}
          after
            stop(pid)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Executes a list of `{sql, params}` statements inside an explicit database
  transaction (`BEGIN` ... `COMMIT`, or `ROLLBACK` on failure) on the persistent
  or transient worker for `profile`.
  """
  @spec execute_transaction_for_profile(ConnectionProfile.t(), [{String.t(), [term()]}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def execute_transaction_for_profile(%ConnectionProfile{} = profile, statements)
      when is_list(statements) do
    case with_worker(profile, fn pid -> execute_transaction(pid, statements) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes `{sql, params}` statements inside a single DB transaction on `worker`.
  """
  @spec execute_transaction(pid() | atom(), [{String.t(), [term()]}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def execute_transaction(worker, statements) when is_list(statements) do
    GenServer.call(worker, {:execute_transaction, statements}, 30_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Executes a SQL query on the connection worker process.
  Returns `{:ok, %{columns: [String.t()], rows: [list()]}}` or `{:error, term()}`.
  """
  def execute_query(worker, sql, params \\ []) when is_binary(sql) do
    GenServer.call(worker, {:execute_query, sql, params}, 30_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Returns the current connection status (`:connected`, `:disconnected`, etc.).
  """
  def get_status(worker) do
    GenServer.call(worker, :get_status, 1_000)
  catch
    :exit, _ -> :disconnected
  end

  @doc """
  Returns the normalized driver atom for this worker.
  """
  def get_driver(worker) do
    GenServer.call(worker, :get_driver, 1_000)
  catch
    :exit, _ -> :sqlite
  end

  @doc """
  Tests connection for either a ConnectionProfile struct or a running worker PID.
  Returns `:ok` or `{:error, term()}`.
  """
  def test_connection(%ConnectionProfile{} = profile) do
    with_transient_worker(profile, &test_connection/1)
  end

  def test_connection(pid) when is_pid(pid) or is_atom(pid) do
    case execute_query(pid, probe_query(pid)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(pid) when is_pid(pid) or is_atom(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp with_transient_worker(%ConnectionProfile{} = profile, fun) do
    case GenServer.start(__MODULE__, {profile, []}) do
      {:ok, pid} ->
        try do
          fun.(pid)
        after
          stop(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Server Callbacks

  @impl true
  def init({%ConnectionProfile{} = profile, _opts}) do
    Process.flag(:trap_exit, true)
    broadcast_status(profile.id, :connecting)

    case connect_db(profile) do
      {:ok, state} ->
        broadcast_status(profile.id, :connected)
        {:ok, Map.put(state, :status, :connected)}

      {:error, reason} ->
        broadcast_status(profile.id, :disconnected)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute_query, sql, params}, _from, state) do
    case ensure_connected(state) do
      {:ok, active_state} ->
        case run_query(active_state.driver, active_state.conn, sql, params) do
          {:ok, res} ->
            {:reply, {:ok, res}, active_state}

          {:error, reason} ->
            {:reply, {:error, reason}, active_state}
        end

      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}
    end
  end

  @impl true
  def handle_call({:execute_transaction, statements}, _from, state) do
    case ensure_connected(state) do
      {:ok, active_state} ->
        result = run_transaction(active_state.driver, active_state.conn, statements)
        {:reply, result, active_state}

      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}
    end
  end

  @impl true
  def handle_call(:get_driver, _from, state) do
    {:reply, state.driver, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, Map.get(state, :status, :connected), state}
  end

  defp run_transaction(_driver, _conn, []), do: {:ok, 0}

  defp run_transaction(driver, conn, statements) do
    with {:ok, _} <- run_query(driver, conn, "BEGIN", []),
         :ok <- run_transaction_steps(driver, conn, statements),
         {:ok, _} <- run_query(driver, conn, "COMMIT", []) do
      {:ok, length(statements)}
    else
      {:error, reason} ->
        _ = run_query(driver, conn, "ROLLBACK", [])
        {:error, reason}
    end
  end

  defp run_transaction_steps(_driver, _conn, []), do: :ok

  defp run_transaction_steps(driver, conn, [{sql, params} | rest]) do
    case run_query(driver, conn, sql, params) do
      {:ok, _res} -> run_transaction_steps(driver, conn, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{conn: pid} = state) when is_pid(pid) do
    broadcast_status(state.profile.id, :disconnected)
    {:noreply, %{state | conn: nil, status: :disconnected}}
  end

  def handle_info({:EXIT, pid, _reason}, %{tunnel_pid: pid} = state) when is_pid(pid) do
    close_db(state.driver, state.conn)
    broadcast_status(state.profile.id, :disconnected)
    {:noreply, %{state | conn: nil, tunnel_pid: nil, status: :disconnected}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_db(state.driver, state.conn)

    if Map.get(state, :tunnel_pid) do
      SSHTunnel.stop(state.tunnel_pid)
    end

    broadcast_status(state.profile.id, :disconnected)
    :ok
  end

  # Private Helpers

  defp ensure_connected(%{conn: conn} = state) when is_pid(conn) do
    if Process.alive?(conn) do
      {:ok, state}
    else
      reconnect_db(state)
    end
  end

  defp ensure_connected(%{conn: nil} = state), do: reconnect_db(state)
  defp ensure_connected(state), do: {:ok, state}

  defp reconnect_db(state) do
    cleanup_tunnel(state.tunnel_pid)
    broadcast_status(state.profile.id, :connecting)

    case connect_db(state.profile) do
      {:ok, new_state} ->
        broadcast_status(state.profile.id, :connected)
        {:ok, Map.put(new_state, :status, :connected)}

      {:error, reason} ->
        broadcast_status(state.profile.id, :disconnected)
        {:error, reason, %{state | conn: nil, tunnel_pid: nil, status: :disconnected}}
    end
  end

  defp broadcast_status(profile_id, status) do
    if is_binary(profile_id) && Process.whereis(Strata.PubSub) do
      Phoenix.PubSub.broadcast(
        Strata.PubSub,
        "connections",
        {:connection_status, profile_id, status}
      )
    end
  end

  defp probe_query(pid) do
    driver = get_driver(pid)
    adapter = Strata.Adapter.for_driver(driver)
    adapter.probe_query()
  rescue
    _ -> "SELECT 1"
  end

  defp connect_db(%ConnectionProfile{} = profile) do
    driver = Strata.Adapter.normalize_driver(profile.driver)

    with {:ok, host, port, tunnel_pid} <- setup_network(profile, driver) do
      try do
        adapter = Strata.Adapter.for_driver(driver)

        case adapter.connect(profile, host, port) do
          {:ok, conn} ->
            {:ok,
             %{
               driver: driver,
               adapter: adapter,
               conn: conn,
               tunnel_pid: tunnel_pid,
               profile: profile
             }}

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
  end

  defp setup_network(%ConnectionProfile{ssh_profile_id: ssh_id} = profile, driver)
       when is_binary(ssh_id) and ssh_id != "" do
    try do
      case SSHProfileStore.get_profile(ssh_id) do
        nil ->
          {:error, {:ssh_tunnel_failed, "SSH profile '#{ssh_id}' not found"}}

        ssh_profile ->
          target_host = profile.host || "localhost"
          target_port = profile.port || Strata.Adapter.default_port(driver)

          case SSHTunnel.connect(ssh_profile, target_host, target_port) do
            {:ok, local_port, tunnel_pid} ->
              {:ok, "127.0.0.1", local_port, tunnel_pid}

            {:error, reason} ->
              {:error, {:ssh_tunnel_failed, reason}}
          end
      end
    rescue
      e -> {:error, {:ssh_tunnel_failed, Exception.message(e)}}
    catch
      _, reason -> {:error, {:ssh_tunnel_failed, reason}}
    end
  end

  defp setup_network(profile, _driver) do
    {:ok, profile.host, profile.port, nil}
  end

  defp cleanup_tunnel(nil), do: :ok
  defp cleanup_tunnel(pid) when is_pid(pid), do: SSHTunnel.stop(pid)

  defp run_query(driver, conn, sql, params) do
    adapter = Strata.Adapter.for_driver(driver)
    adapter.execute_query(conn, sql, params)
  end

  defp close_db(_driver, nil), do: :ok

  defp close_db(driver, conn) do
    adapter = Strata.Adapter.for_driver(driver)
    adapter.close(conn)
  rescue
    _ -> :ok
  end
end
