defmodule Strata.SchemaInspector do
  @moduledoc """
  Helper module for querying real schemas, tables, views, and columns from Postgres, MySQL, and SQLite databases.
  Reuses persistent workers via `Strata.ConnectionWorker.with_worker/2` and dispatches per-driver queries.
  """

  alias Strata.ConnectionProfile
  alias Strata.ConnectionWorker

  @doc """
  Inspects schema structure for a given ConnectionProfile in a single connection pass.
  Returns tree nodes for Sidebar.
  """
  def fetch_tree_nodes(%ConnectionProfile{} = profile, opts \\ []) do
    case ConnectionWorker.with_worker(profile, fn worker ->
           build_online_nodes(profile, worker, opts)
         end) do
      {:ok, node} ->
        node

      {:error, reason} ->
        fetch_fallback_nodes(profile, reason, opts)
    end
  rescue
    e -> fetch_fallback_nodes(profile, Exception.message(e), opts)
  end

  defp build_online_nodes(%ConnectionProfile{} = profile, worker, opts) do
    driver = Strata.Adapter.normalize_driver(profile.driver)
    expanded? = Keyword.get(opts, :expanded?, true)
    schema_entries = fetch_schemas_and_tables(worker, driver, profile)
    children = build_tree_children(profile.id, schema_entries)

    %{
      id: profile.id,
      label: connection_label(profile),
      type: :connection,
      expanded?: expanded?,
      children: children
    }
  end

  @doc """
  Formats the sidebar connection label as `Name · Database (DRIVER)` when database
  is set and differs from connection name, or `Name (DRIVER)` otherwise.
  """
  def connection_label(%ConnectionProfile{} = profile) do
    driver = Strata.Adapter.normalize_driver(profile.driver)
    driver_badge = short_driver_label(driver)

    display_name =
      if is_binary(profile.name) and String.trim(profile.name) != "",
        do: String.trim(profile.name),
        else: "Connection"

    raw_db = to_string(profile.database || "") |> String.trim()

    db_name =
      cond do
        raw_db == "" -> ""
        driver == :sqlite and raw_db != ":memory:" -> Path.basename(raw_db)
        true -> raw_db
      end

    if db_name != "" and String.downcase(db_name) != String.downcase(display_name) do
      "#{display_name} · #{db_name} (#{driver_badge})"
    else
      "#{display_name} (#{driver_badge})"
    end
  end

  @doc """
  Builds Sidebar children for a connection: flattens table/view nodes directly under
  the connection when only one schema exists, and groups into schema folders when
  multiple schemas are present.
  """
  def build_tree_children(profile_id, [{schema_name, objects}]) do
    case build_table_nodes(profile_id, schema_name, objects) do
      [] ->
        [
          %{
            id: "#{profile_id}_#{schema_name}_empty",
            label: "(No tables in #{schema_name})",
            type: :schema,
            schema: schema_name,
            expanded?: false,
            children: []
          }
        ]

      table_nodes ->
        table_nodes
    end
  end

  def build_tree_children(profile_id, schema_entries) when is_list(schema_entries) do
    Enum.map(schema_entries, fn {schema_name, objects} ->
      %{
        id: "#{profile_id}_schema_#{schema_name}",
        label: schema_name,
        type: :schema,
        schema: schema_name,
        expanded?: schema_name in ["public", "main"],
        children: build_table_nodes(profile_id, schema_name, objects)
      }
    end)
  end

  defp build_table_nodes(profile_id, schema_name, objects) do
    objects
    |> Enum.sort_by(fn {tbl, obj_type} ->
      {if(obj_type == :view, do: 1, else: 0), String.downcase(tbl)}
    end)
    |> Enum.map(fn {tbl, obj_type} ->
      %{
        id: "#{profile_id}_#{schema_name}_tbl_#{tbl}",
        label: tbl,
        type: obj_type,
        profile_id: profile_id,
        schema: schema_name,
        children: []
      }
    end)
  end

  @doc """
  Returns a compact display badge for database drivers in the sidebar tree.
  """
  def short_driver_label(driver) do
    case Strata.Adapter.normalize_driver(driver) do
      :postgres -> "PG"
      :mysql -> "MySQL"
      :sqlite -> "SQLite"
      other -> String.upcase(to_string(other))
    end
  end

  @doc """
  Returns true if `schema_name` is a PostgreSQL internal/temporary system schema that should be hidden.
  """
  def system_schema?(schema_name) when is_binary(schema_name) do
    schema_name in ["pg_catalog", "information_schema", "pg_toast"] or
      String.starts_with?(schema_name, "pg_temp") or
      String.starts_with?(schema_name, "pg_toast_temp")
  end

  def system_schema?(_), do: false

  defp fetch_schemas_and_tables(worker, :postgres, _profile) do
    sql = """
    SELECT s.schema_name, t.table_name, t.table_type
    FROM information_schema.schemata s
    LEFT JOIN information_schema.tables t
      ON t.table_schema = s.schema_name
     AND t.table_type IN ('BASE TABLE', 'VIEW')
    WHERE s.schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND s.schema_name NOT LIKE 'pg_temp%'
      AND s.schema_name NOT LIKE 'pg_toast_temp%'
    ORDER BY s.schema_name, t.table_name;
    """

    case ConnectionWorker.execute_query(worker, sql) do
      {:ok, %{rows: rows}} when rows != [] ->
        rows
        |> Enum.reject(fn [s | _] -> system_schema?(to_string(s)) end)
        |> Enum.group_by(fn [s | _] -> to_string(s) end)
        |> Enum.sort_by(fn {schema_name, _} -> schema_name end)
        |> Enum.map(fn {schema_name, schema_rows} ->
          objs =
            schema_rows
            |> Enum.reject(fn [_s, tbl, _type] -> is_nil(tbl) end)
            |> Enum.map(fn [_s, tbl, ttype] ->
              {to_string(tbl), normalize_object_type(ttype)}
            end)

          {schema_name, objs}
        end)

      _ ->
        schemas = list_postgres_schemas(worker)

        Enum.map(schemas, fn s ->
          {s, Enum.map(list_tables_in_schema(worker, :postgres, s), &{&1, :table})}
        end)
    end
  end

  defp fetch_schemas_and_tables(worker, :mysql, profile) do
    [schema_name | _] = list_schemas_for_driver(worker, :mysql, profile)

    sql = """
    SELECT table_name, table_type
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_type IN ('BASE TABLE', 'VIEW')
    ORDER BY table_name;
    """

    objs =
      case ConnectionWorker.execute_query(worker, sql) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [tbl, ttype] -> {to_string(tbl), normalize_object_type(ttype)} end)

        _ ->
          []
      end

    [{schema_name, objs}]
  end

  defp fetch_schemas_and_tables(worker, :sqlite, _profile) do
    sql = """
    SELECT name, type
    FROM sqlite_master
    WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
    ORDER BY name;
    """

    objs =
      case ConnectionWorker.execute_query(worker, sql) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [tbl, ttype] -> {to_string(tbl), normalize_object_type(ttype)} end)

        _ ->
          []
      end

    [{"main", objs}]
  end

  defp fetch_schemas_and_tables(worker, driver, _profile) do
    [{"public", Enum.map(list_tables_in_schema(worker, driver, "public"), &{&1, :table})}]
  end

  defp normalize_object_type(ttype) do
    if String.upcase(to_string(ttype || "")) == "VIEW", do: :view, else: :table
  end

  def fetch_fallback_nodes(%ConnectionProfile{} = profile, reason \\ nil, opts \\ []) do
    expanded? = Keyword.get(opts, :expanded?, true)

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
      label: connection_label(profile),
      type: :connection,
      expanded?: expanded?,
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

  def list_schemas_for_driver(worker, :postgres, _profile) do
    list_postgres_schemas(worker)
  end

  def list_schemas_for_driver(_worker, :sqlite, _profile), do: ["main"]

  def list_schemas_for_driver(worker, :mysql, profile) do
    case ConnectionWorker.execute_query(worker, "SELECT DATABASE()") do
      {:ok, %{rows: [[db]]}} when is_binary(db) and db != "" -> [db]
      _ -> [profile.database || "public"]
    end
  end

  def list_schemas_for_driver(_worker, _driver, _profile), do: ["public"]

  def list_postgres_schemas(worker) do
    sql = """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND schema_name NOT LIKE 'pg_temp%'
      AND schema_name NOT LIKE 'pg_toast_temp%'
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
    case Strata.Adapter.normalize_driver(driver) do
      :postgres ->
        sql = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = $1 AND table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY table_name;
        """

        case ConnectionWorker.execute_query(worker, sql, [schema_name]) do
          {:ok, %{rows: rows}} -> Enum.map(rows, fn [tbl] -> to_string(tbl) end)
          _ -> []
        end

      normalized ->
        list_tables(worker, normalized)
    end
  end

  def list_tables(worker, driver) do
    case Strata.Adapter.normalize_driver(driver) do
      :postgres ->
        list_tables_in_schema(worker, :postgres, "public")

      :mysql ->
        sql = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type IN ('BASE TABLE', 'VIEW')
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
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
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

  @doc """
  Inspects column metadata, primary keys, defaults, and foreign-key constraints
  for a table on Postgres, MySQL, or SQLite.
  Returns `{:ok, %{columns: [String.t()], rows: [list()], primary_keys: [String.t()]}}`
  or `{:error, term()}`.
  """
  @spec fetch_table_schema(
          Strata.ConnectionProfile.t() | pid() | atom(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{columns: [String.t()], rows: [list()], primary_keys: [String.t()]}}
          | {:error, term()}
  def fetch_table_schema(profile_or_worker, table_name, opts \\ [])

  def fetch_table_schema(%Strata.ConnectionProfile{} = profile, table_name, opts) do
    schema = Keyword.get(opts, :schema)

    case ConnectionWorker.with_worker(profile, fn worker ->
           fetch_table_schema_with_worker(worker, profile.driver, table_name, schema)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_table_schema(worker, table_name, opts) do
    driver = Keyword.get(opts, :driver, ConnectionWorker.get_driver(worker))
    schema = Keyword.get(opts, :schema)
    fetch_table_schema_with_worker(worker, driver, table_name, schema)
  end

  defp fetch_table_schema_with_worker(worker, driver, table_name, schema) do
    headers = ["Column", "Type", "Nullable", "Default", "Key", "Extra"]

    case Strata.Adapter.normalize_driver(driver) do
      :sqlite ->
        q_table = Strata.Adapter.quote_identifier(:sqlite, table_name)

        with {:ok, %{rows: info_rows}} <-
               ConnectionWorker.execute_query(worker, "PRAGMA table_info(#{q_table});") do
          fk_map =
            case ConnectionWorker.execute_query(worker, "PRAGMA foreign_key_list(#{q_table});") do
              {:ok, %{rows: fk_rows}} ->
                Map.new(fk_rows, fn fk ->
                  from_col = to_string(Enum.at(fk, 3, ""))
                  ref_tbl = to_string(Enum.at(fk, 2, ""))
                  ref_col = to_string(Enum.at(fk, 4, ""))
                  {from_col, "-> #{ref_tbl}(#{ref_col})"}
                end)

              _ ->
                %{}
            end

          primary_keys =
            info_rows
            |> Enum.filter(fn row -> (Enum.at(row, 5, 0) || 0) > 0 end)
            |> Enum.sort_by(fn row -> Enum.at(row, 5, 0) end)
            |> Enum.map(fn row -> to_string(Enum.at(row, 1)) end)

          rows =
            Enum.map(info_rows, fn [_cid, name, type, notnull, dflt, pk | _] ->
              name_str = to_string(name)
              type_str = to_string(type || "")
              nullable = if notnull == 1, do: "NO", else: "YES"
              dflt_str = if is_nil(dflt), do: nil, else: to_string(dflt)
              fk_note = Map.get(fk_map, name_str)

              key_badge =
                cond do
                  is_integer(pk) and pk > 0 -> "PRI"
                  fk_note != nil -> "FK"
                  true -> ""
                end

              extra = fk_note || ""
              [name_str, type_str, nullable, dflt_str, key_badge, extra]
            end)

          {:ok, %{columns: headers, rows: rows, primary_keys: primary_keys}}
        end

      :postgres ->
        pg_schema = if is_binary(schema) and schema != "", do: schema, else: "public"

        col_sql = """
        SELECT c.column_name,
               c.data_type,
               c.is_nullable,
               c.column_default,
               COALESCE(
                 (SELECT CASE tc.constraint_type
                           WHEN 'PRIMARY KEY' THEN 'PRI'
                           WHEN 'UNIQUE' THEN 'UNI'
                           WHEN 'FOREIGN KEY' THEN 'FK'
                           ELSE ''
                         END
                  FROM information_schema.key_column_usage kcu
                  JOIN information_schema.table_constraints tc
                    ON tc.constraint_name = kcu.constraint_name
                   AND tc.table_schema = kcu.table_schema
                  WHERE kcu.table_schema = c.table_schema
                    AND kcu.table_name = c.table_name
                    AND kcu.column_name = c.column_name
                  ORDER BY CASE tc.constraint_type
                             WHEN 'PRIMARY KEY' THEN 1
                             WHEN 'FOREIGN KEY' THEN 2
                             ELSE 3
                           END
                  LIMIT 1),
                 ''
               ) AS key_type
        FROM information_schema.columns c
        WHERE c.table_schema = $1 AND c.table_name = $2
        ORDER BY c.ordinal_position;
        """

        case ConnectionWorker.execute_query(worker, col_sql, [pg_schema, table_name]) do
          {:ok, %{rows: pg_rows}} ->
            rows =
              Enum.map(pg_rows, fn [name, dtype, nullable, dflt, key_type] ->
                [
                  to_string(name),
                  to_string(dtype || ""),
                  to_string(nullable || "YES"),
                  if(is_nil(dflt), do: nil, else: to_string(dflt)),
                  to_string(key_type || ""),
                  ""
                ]
              end)

            primary_keys =
              rows
              |> Enum.filter(fn [_, _, _, _, key_type, _] -> key_type == "PRI" end)
              |> Enum.map(&hd/1)

            {:ok, %{columns: headers, rows: rows, primary_keys: primary_keys}}

          {:error, reason} ->
            {:error, reason}
        end

      :mysql ->
        target_schema = if is_binary(schema) and schema != "", do: schema, else: ""

        col_sql = """
        SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA
        FROM information_schema.columns
        WHERE TABLE_SCHEMA = COALESCE(NULLIF(?, ''), DATABASE()) AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION;
        """

        case ConnectionWorker.execute_query(worker, col_sql, [target_schema, table_name]) do
          {:ok, %{rows: my_rows}} ->
            rows =
              Enum.map(my_rows, fn [name, dtype, nullable, dflt, key_type, extra] ->
                [
                  to_string(name),
                  to_string(dtype || ""),
                  to_string(nullable || "YES"),
                  if(is_nil(dflt), do: nil, else: to_string(dflt)),
                  to_string(key_type || ""),
                  to_string(extra || "")
                ]
              end)

            primary_keys =
              rows
              |> Enum.filter(fn [_, _, _, _, key_type, _] -> key_type == "PRI" end)
              |> Enum.map(&hd/1)

            {:ok, %{columns: headers, rows: rows, primary_keys: primary_keys}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :unsupported_driver}
    end
  end

  @doc """
  Prefetches `{schema, table_name, [col_names]}` for all tables/views in `profile`
  using a single metadata query (Postgres/MySQL) or table_info scan (SQLite).
  """
  @spec fetch_all_columns(ConnectionProfile.t()) ::
          {:ok, [{String.t() | nil, String.t(), [String.t()]}]} | {:error, term()}
  def fetch_all_columns(%ConnectionProfile{} = profile) do
    case ConnectionWorker.with_worker(profile, fn worker ->
           fetch_all_columns_with_worker(worker, profile.driver)
         end) do
      {:ok, res} -> res
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_all_columns_with_worker(worker, driver) do
    case Strata.Adapter.normalize_driver(driver) do
      :postgres ->
        sql = """
        SELECT table_schema, table_name, column_name
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND table_schema NOT LIKE 'pg_temp%'
          AND table_schema NOT LIKE 'pg_toast_temp%'
        ORDER BY table_schema, table_name, ordinal_position;
        """

        case ConnectionWorker.execute_query(worker, sql) do
          {:ok, %{rows: rows}} ->
            entries =
              rows
              |> Enum.group_by(fn [s, t, _c] -> {to_string(s), to_string(t)} end, fn [_s, _t, c] ->
                to_string(c)
              end)
              |> Enum.map(fn {{s, t}, cols} -> {s, t, cols} end)

            {:ok, entries}

          {:error, reason} ->
            {:error, reason}
        end

      :mysql ->
        sql = """
        SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME
        FROM information_schema.columns
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME, ORDINAL_POSITION;
        """

        case ConnectionWorker.execute_query(worker, sql) do
          {:ok, %{rows: rows}} ->
            entries =
              rows
              |> Enum.group_by(fn [s, t, _c] -> {to_string(s), to_string(t)} end, fn [_s, _t, c] ->
                to_string(c)
              end)
              |> Enum.map(fn {{s, t}, cols} -> {s, t, cols} end)

            {:ok, entries}

          {:error, reason} ->
            {:error, reason}
        end

      :sqlite ->
        tbl_sql =
          "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 100;"

        case ConnectionWorker.execute_query(worker, tbl_sql) do
          {:ok, %{rows: tbl_rows}} ->
            entries =
              Enum.flat_map(tbl_rows, fn [tbl] ->
                t_name = to_string(tbl)
                q_tbl = Strata.Adapter.quote_identifier(:sqlite, t_name)

                case ConnectionWorker.execute_query(worker, "PRAGMA table_info(#{q_tbl});") do
                  {:ok, %{rows: info_rows}} ->
                    cols =
                      Enum.map(info_rows, &to_string(Enum.at(&1, 1, "")))
                      |> Enum.reject(&(&1 == ""))

                    if cols != [], do: [{"main", t_name, cols}], else: []

                  _ ->
                    []
                end
              end)

            {:ok, entries}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :unsupported_driver}
    end
  end
end
