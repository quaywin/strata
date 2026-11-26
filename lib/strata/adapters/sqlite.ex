defmodule Strata.Adapter.SQLite do
  @moduledoc """
  SQLite3 database adapter implementing `Strata.Adapter` behaviour.
  """
  @behaviour Strata.Adapter

  alias Strata.ConnectionProfile

  @impl true
  def default_port, do: 0

  @impl true
  def probe_query, do: "SELECT 1"

  @impl true
  def connect(%ConnectionProfile{} = profile, _host, _port) do
    db_path = profile.database || ":memory:"

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def execute_query(conn, sql, params) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- maybe_bind(conn, stmt, params),
               {:ok, cols} <- Exqlite.Sqlite3.columns(conn, stmt),
               {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, stmt) do
            str_cols = Enum.map(cols, &to_string/1)
            {:ok, %{columns: str_cols, rows: rows}}
          else
            {:error, reason} -> {:error, reason}
          end
        after
          _ = Exqlite.Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_bind(_conn, _stmt, []), do: :ok
  defp maybe_bind(_conn, _stmt, nil), do: :ok

  defp maybe_bind(_conn, stmt, params) when is_list(params) do
    Exqlite.Sqlite3.bind(stmt, params)
  end

  @impl true
  def list_schemas(_conn) do
    ["main"]
  end

  @impl true
  def list_tables(conn, _schema) do
    sql = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name;
    """

    case execute_query(conn, sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [tbl] -> to_string(tbl) end)

      _ ->
        []
    end
  end

  @impl true
  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  rescue
    _ -> :ok
  end
end
