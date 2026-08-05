defmodule DBData.LogStoreTest do
  use ExUnit.Case
  alias DBData.LogStore

  setup do
    LogStore.clear_logs()
    :ok
  end

  test "adds and retrieves logs by tab" do
    LogStore.add_log("tab1", %{status: :ok, query: "SELECT 1", duration_ms: 12, rows: 2})
    assert [%{query: "SELECT 1"}] = LogStore.get_logs("tab1")
  end

  test "filters logs by tab_id and retrieves all logs when tab_id is nil" do
    LogStore.add_log("tab1", %{status: :ok, query: "SELECT 1", duration_ms: 10, rows: 1})
    LogStore.add_log("tab2", %{status: :ok, query: "SELECT 2", duration_ms: 20, rows: 2})

    tab1_logs = LogStore.get_logs("tab1")
    assert length(tab1_logs) == 1
    assert hd(tab1_logs).query == "SELECT 1"

    all_logs = LogStore.get_logs()
    assert length(all_logs) == 2
    queries = Enum.map(all_logs, & &1.query)
    assert "SELECT 1" in queries
    assert "SELECT 2" in queries
  end

  test "prunes logs when capacity limit is reached" do
    for i <- 1..1050 do
      LogStore.add_log("tab1", %{status: :ok, query: "SELECT #{i}", duration_ms: 1, rows: 1})
    end

    logs = LogStore.get_logs()
    assert length(logs) <= 1000
  end
end
