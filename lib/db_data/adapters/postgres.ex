defmodule DBData.Adapter.Postgres do
  @moduledoc """
  PostgreSQL database adapter implementing `DBData.Adapter` behaviour.
  """
  @behaviour DBData.Adapter

  alias DBData.ConnectionProfile

  @impl true
  def default_port, do: 5432

  @impl true
  def probe_query, do: "SELECT 1"

  @impl true
  def connect(%ConnectionProfile{} = profile, host, port) do
    _ = Application.ensure_all_started(:postgrex)

    pg_opts =
      [
        hostname: host || "localhost",
        port: port || default_port(),
        username: profile.username || "postgres",
        password: profile.password || "",
        database: profile.database || "postgres"
      ] ++ Map.to_list(profile.options || %{})

    case Postgrex.start_link(pg_opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def execute_query(conn, sql, params) when is_pid(conn) do
    case Postgrex.query(conn, sql, params) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        str_cols = Enum.map(cols, &to_string/1)
        {:ok, %{columns: str_cols, rows: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_schemas(conn) when is_pid(conn) do
    sql = """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    ORDER BY schema_name;
    """

    case execute_query(conn, sql, []) do
      {:ok, %{rows: rows}} ->
        schemas = Enum.map(rows, fn [s] -> to_string(s) end)
        if schemas != [], do: schemas, else: ["public"]

      _ ->
        ["public"]
    end
  end

  @impl true
  def list_tables(conn, schema) when is_pid(conn) do
    schema_name = if is_binary(schema) and schema != "", do: schema, else: "public"

    sql = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = $1 AND table_type = 'BASE TABLE'
    ORDER BY table_name;
    """

    case execute_query(conn, sql, [schema_name]) do
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
