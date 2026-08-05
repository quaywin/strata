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
end
