defmodule Strata.SchemaInspectorTest do
  use ExUnit.Case, async: true

  alias Strata.{ConnectionProfile, ConnectionWorker, SchemaInspector}

  test "fetch_table_schema/3 inspects columns, defaults, primary keys, and foreign keys on SQLite" do
    profile = %ConnectionProfile{
      id: "schema_sqlite_#{System.unique_integer([:positive])}",
      name: "Schema SQLite",
      driver: :sqlite,
      database: ":memory:"
    }

    {:ok, worker} = ConnectionWorker.start_link(profile)
    on_exit(fn -> ConnectionWorker.stop(worker) end)

    assert {:ok, _} =
             ConnectionWorker.execute_query(
               worker,
               "CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
             )

    assert {:ok, _} =
             ConnectionWorker.execute_query(
               worker,
               """
               CREATE TABLE members (
                 id INTEGER PRIMARY KEY,
                 team_id INTEGER REFERENCES teams(id),
                 email TEXT NOT NULL,
                 role TEXT DEFAULT 'member'
               )
               """
             )

    assert {:ok, schema_info} =
             SchemaInspector.fetch_table_schema(worker, "members", driver: :sqlite)

    assert schema_info.columns == ["Column", "Type", "Nullable", "Default", "Key", "Extra"]
    assert schema_info.primary_keys == ["id"]

    assert [
             ["id", "INTEGER", "YES", nil, "PRI", ""],
             ["team_id", "INTEGER", "YES", nil, "FK", "-> teams(id)"],
             ["email", "TEXT", "NO", nil, "", ""],
             ["role", "TEXT", "YES", "'member'", "", ""]
           ] = schema_info.rows
  end

  test "fetch_tree_nodes distinguishes tables and views cleanly on SQLite" do
    db_path =
      Path.join(System.tmp_dir!(), "strata_tree_#{System.unique_integer([:positive])}.sqlite")

    on_exit(fn -> File.rm(db_path) end)

    profile = %ConnectionProfile{
      id: "tree_sqlite_#{System.unique_integer([:positive])}",
      name: "Tree SQLite",
      driver: :sqlite,
      database: db_path
    }

    assert {:ok, _} =
             ConnectionWorker.execute_query_for_profile(
               profile,
               "CREATE TABLE users (id INTEGER PRIMARY KEY)"
             )

    assert {:ok, _} =
             ConnectionWorker.execute_query_for_profile(
               profile,
               "CREATE VIEW active_users AS SELECT id FROM users"
             )

    tree = SchemaInspector.fetch_tree_nodes(profile)

    # Single-schema database flattens tables & views directly under connection while preserving :schema metadata
    assert [
             %{label: "users", type: :table, schema: "main"},
             %{label: "active_users", type: :view, schema: "main"}
           ] = tree.children
  end

  test "build_tree_children groups into schema folders only when >= 2 schemas exist" do
    multi =
      SchemaInspector.build_tree_children("p1", [
        {"analytics", [{"events", :table}]},
        {"public", [{"users", :table}]}
      ])

    assert [
             %{
               label: "analytics",
               type: :schema,
               expanded?: false,
               children: [%{label: "events"}]
             },
             %{label: "public", type: :schema, expanded?: true, children: [%{label: "users"}]}
           ] = multi
  end

  test "system_schema?/1 filters out pg_temp* and pg_toast_temp* schemas while keeping user schemas" do
    assert SchemaInspector.system_schema?("pg_temp_1")
    assert SchemaInspector.system_schema?("pg_temp4")
    assert SchemaInspector.system_schema?("pg_toast_temp_2")
    assert SchemaInspector.system_schema?("pg_catalog")
    assert SchemaInspector.system_schema?("information_schema")
    refute SchemaInspector.system_schema?("public")
    refute SchemaInspector.system_schema?("analytics")
  end

  test "connection_label includes both profile name and database name without duplicating identical names" do
    pg = %ConnectionProfile{id: "c1", name: "Prod", driver: :postgres, database: "ecommerce_prod"}
    assert SchemaInspector.connection_label(pg) == "Prod · ecommerce_prod (PG)"

    same = %ConnectionProfile{
      id: "c2",
      name: "ecommerce_prod",
      driver: :postgres,
      database: "ecommerce_prod"
    }

    assert SchemaInspector.connection_label(same) == "ecommerce_prod (PG)"

    sq = %ConnectionProfile{
      id: "c3",
      name: "Local",
      driver: :sqlite,
      database: "/tmp/orders.sqlite"
    }

    assert SchemaInspector.connection_label(sq) == "Local · orders.sqlite (SQLite)"
  end

  test "fetch_fallback_nodes formats exception structs cleanly instead of raw inspect" do
    profile = %ConnectionProfile{id: "c_err", name: "PG", driver: :postgres}

    err = %DBConnection.ConnectionError{
      message: "tcp connect (127.0.0.1:5432): connection refused"
    }

    tree = SchemaInspector.fetch_fallback_nodes(profile, err)

    assert [%{label: "(Offline: tcp connect (127.0.0.1:5432): connection refused)"}] =
             tree.children
  end
end
