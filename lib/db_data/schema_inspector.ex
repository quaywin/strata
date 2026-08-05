defmodule DBData.SchemaInspector do
  @moduledoc """
  Helper module for querying real schemas, tables, views, and columns from Postgres, MySQL, and SQLite databases.
  """

  alias DBData.ConnectionProfile
  alias DBData.ConnectionWorker

  @doc """
  Inspects schema structure for a given ConnectionProfile.
  Returns tree nodes for Sidebar.
  """
  def fetch_tree_nodes(%ConnectionProfile{} = profile) do
    case ConnectionWorker.test_connection(profile) do
      :ok ->
        fetch_online_nodes(profile)

      {:error, reason} ->
        fetch_fallback_nodes(profile, reason)

      _ ->
        fetch_fallback_nodes(profile, "Unknown error")
    end
  end

  def fetch_online_nodes(%ConnectionProfile{} = profile) do
    {:ok, worker} = ConnectionWorker.start_link(profile)

    try do
      driver = DBData.Adapter.normalize_driver(profile.driver)

      schemas =
        try do
          list_postgres_schemas(worker)
        rescue
          _ -> ["public"]
        end

      schema_nodes =
        Enum.map(schemas, fn schema_name ->
          tables =
            try do
              list_tables_in_schema(worker, driver, schema_name)
            rescue
              _ -> []
            end

          table_nodes =
            Enum.map(tables, fn tbl ->
              %{
                id: "#{profile.id}_#{schema_name}_tbl_#{tbl}",
                label: tbl,
                type: :table,
                children: []
              }
            end)

          %{
            id: "#{profile.id}_schema_#{schema_name}",
            label: schema_name,
            type: :schema,
            expanded?: schema_name == "public" or schema_name == "main",
            children: table_nodes
          }
        end)

      display_name = if profile.name && profile.name != "", do: profile.name, else: "Connection"

      %{
        id: profile.id,
        label: "#{display_name} (#{String.upcase(to_string(driver))})",
        type: :connection,
        expanded?: true,
        children: schema_nodes
      }
    after
      ConnectionWorker.stop(worker)
    end
  rescue
    e -> fetch_fallback_nodes(profile, Exception.message(e))
  end

  def fetch_fallback_nodes(%ConnectionProfile{} = profile, reason \\ nil) do
    driver_label = String.upcase(to_string(profile.driver))
    display_name = if profile.name && profile.name != "", do: profile.name, else: "Connection"

    err_msg =
      case reason do
        nil -> "(Offline)"
        :econnrefused -> "(Offline: Connection refused on #{profile.host}:#{profile.port})"
        :timeout -> "(Offline: Connection timeout)"
        msg when is_binary(msg) -> "(Offline: #{msg})"
        other -> "(Offline: #{inspect(other)})"
      end

    %{
      id: profile.id,
      label: "#{display_name} (#{driver_label})",
      type: :connection,
      expanded?: true,
      children: [
        %{
          id: "#{profile.id}_status",
          label: err_msg,
          type: :schema,
          expanded?: false,
          children: []
        }
      ]
    }
  end

  def list_postgres_schemas(worker) do
    list_tables(worker, :postgres) # Fallback / generic helper entry point
    sql = """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    ORDER BY schema_name;
    """

    case ConnectionWorker.execute_query(worker, sql) do
      {:ok, %{rows: rows}} ->
        schemas = Enum.map(rows, fn [s] -> to_string(s) end)
        if schemas != [], do: schemas, else: ["public"]

      _ ->
        ["public"]
    end
  end

  def list_tables_in_schema(worker, driver, schema_name) do
    case driver do
      :postgres ->
        sql = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = $1 AND table_type = 'BASE TABLE'
        ORDER BY table_name;
        """

        case ConnectionWorker.execute_query(worker, sql, [schema_name]) do
          {:ok, %{rows: rows}} -> Enum.map(rows, fn [tbl] -> to_string(tbl) end)
          _ -> []
        end

      _ ->
        list_tables(worker, driver)
    end
  end

  def list_tables(worker, driver) do
    case driver do
      :postgres ->
        list_tables_in_schema(worker, :postgres, "public")

      :mysql ->
        sql = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
        ORDER BY table_name;
        """

        case ConnectionWorker.execute_query(worker, sql) do
          {:ok, %{rows: rows}} -> Enum.map(rows, fn [tbl] -> to_string(tbl) end)
          _ -> []
        end

      :sqlite ->
        sql = """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name;
        """

        case ConnectionWorker.execute_query(worker, sql) do
          {:ok, %{rows: rows}} -> Enum.map(rows, fn [tbl] -> to_string(tbl) end)
          _ -> []
        end

      _ ->
        []
    end
  end
end
