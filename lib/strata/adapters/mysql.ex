defmodule Strata.Adapter.MySQL do
  @moduledoc """
  MySQL / MariaDB database adapter implementing `Strata.Adapter` behaviour.
  """
  @behaviour Strata.Adapter

  alias Strata.ConnectionProfile

  @impl true
  def default_port, do: 3306

  @impl true
  def probe_query, do: "SELECT 1"

  @impl true
  def connect(%ConnectionProfile{} = profile, host, port) do
    _ = Application.ensure_all_started(:myxql)

    case MyXQL.start_link(mysql_opts(profile, host, port)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def test_connection(%ConnectionProfile{} = profile, host, port) do
    _ = Application.ensure_all_started(:myxql)
    opts = Keyword.put_new(mysql_opts(profile, host, port), :disconnect_on_error_codes, [])

    Strata.Adapter.run_isolated(fn ->
      case MyXQL.Connection.connect(opts) do
        {:ok, state} ->
          _ = MyXQL.Connection.disconnect(:normal, state)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp mysql_opts(%ConnectionProfile{} = profile, host, port) do
    [
      hostname: host || "localhost",
      port: port || default_port(),
      username: profile.username || "root",
      password: profile.password || "",
      database: profile.database
    ] ++ Map.to_list(profile.options || %{})
  end

  @impl true
  def execute_query(conn, sql, params) when is_pid(conn) do
    case MyXQL.query(conn, sql, params) do
      {:ok, %MyXQL.Result{columns: cols, rows: rows}} ->
        str_cols = Enum.map(cols, &to_string/1)
        {:ok, %{columns: str_cols, rows: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_schemas(_conn) do
    ["public"]
  end

  @impl true
  def list_tables(conn, _schema) when is_pid(conn) do
    sql = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
    ORDER BY table_name;
    """

    case execute_query(conn, sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [tbl] -> to_string(tbl) end)

      _ ->
        []
    end
  end

  @impl true
  def close(conn) when is_pid(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn)
    end
  rescue
    _ -> :ok
  end

  def close(_conn), do: :ok
end
