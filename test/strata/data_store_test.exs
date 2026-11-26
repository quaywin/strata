defmodule Strata.DataStoreTest do
  use ExUnit.Case
  alias Strata.DataStore

  setup do
    DataStore.clear()
    :ok
  end

  test "stores query result set and retrieves paginated rows" do
    columns = ["id", "email"]
    rows = [["1", "a@b.com"], ["2", "c@d.com"]]

    DataStore.put_result_set("tab1", columns, rows, 15)
    assert {^columns, [["1", "a@b.com"]], 2, 15} = DataStore.get_page("tab1", 1, 1)
    assert {^columns, [["2", "c@d.com"]], 2, 15} = DataStore.get_page("tab1", 2, 1)
    assert {^columns, [], 2, 15} = DataStore.get_page("tab1", 3, 1)
  end

  test "handles default total_rows and empty tab" do
    columns = ["id", "name"]
    rows = [["1", "Alice"], ["2", "Bob"], ["3", "Charlie"]]

    DataStore.store_result("tab2", columns, rows)
    assert {^columns, [["1", "Alice"], ["2", "Bob"]], 3, 3} = DataStore.get_page("tab2", 1, 2)

    assert {[], [], 0, 0} = DataStore.get_page("non_existent_tab", 1, 10)
  end

  test "caches, appends, and invalidates connection-scoped table data" do
    cols = ["id", "name"]
    rows = [[1, "Alice"], [2, "Bob"]]

    assert :miss = DataStore.get_table_cache("conn_a", nil, "users")
    assert :ok = DataStore.put_table_cache("conn_a", nil, "users", cols, rows, true)

    assert {:ok, entry} = DataStore.get_table_cache("conn_a", nil, "users")
    assert entry.columns == cols
    assert entry.rows == rows
    assert entry.has_more == true

    # Different connection ID is isolated
    assert :miss = DataStore.get_table_cache("conn_b", nil, "users")

    # Append deduplicates existing rows
    assert :ok =
             DataStore.append_table_cache(
               "conn_a",
               nil,
               "users",
               [[2, "Bob"], [3, "Charlie"]],
               false
             )

    assert {:ok, updated} = DataStore.get_table_cache("conn_a", nil, "users")
    assert updated.rows == [[1, "Alice"], [2, "Bob"], [3, "Charlie"]]
    assert updated.has_more == false

    # Invalidate single table
    assert :ok = DataStore.invalidate_table_cache("conn_a", nil, "users")
    assert :miss = DataStore.get_table_cache("conn_a", nil, "users")
  end

  test "caches and invalidates schema metadata" do
    schema_info = %{columns: ["Column", "Type"], rows: [["id", "INTEGER"]], primary_keys: ["id"]}
    assert :miss = DataStore.get_schema_cache("conn_s", "public", "users")
    assert :ok = DataStore.put_schema_cache("conn_s", "public", "users", schema_info)
    assert {:ok, ^schema_info} = DataStore.get_schema_cache("conn_s", "public", "users")

    assert :ok = DataStore.invalidate_table_cache("conn_s", "public", "users")
    assert :miss = DataStore.get_schema_cache("conn_s", "public", "users")
  end
end
