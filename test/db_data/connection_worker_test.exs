defmodule DBData.ConnectionWorkerTest do
  use ExUnit.Case
  alias DBData.{ConnectionWorker, ConnectionProfile, SSHTunnel, SSHProfile}

  test "connects to local sqlite database and executes query" do
    profile = %ConnectionProfile{id: "sqlite_test", name: "Test SQLite", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)
    assert {:ok, %{columns: ["val"], rows: [[1]]}} = ConnectionWorker.execute_query(pid, "SELECT 1 as val")
  end

  test "executes query with multiple columns and rows on SQLite" do
    profile = %ConnectionProfile{id: "sqlite_test_multi", name: "Test SQLite Multi", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)

    assert {:ok, _} = ConnectionWorker.execute_query(pid, "CREATE TABLE users (id INTEGER, name TEXT)")
    assert {:ok, _} = ConnectionWorker.execute_query(pid, "INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob')")

    assert {:ok, %{columns: ["id", "name"], rows: [[1, "Alice"], [2, "Bob"]]}} =
             ConnectionWorker.execute_query(pid, "SELECT id, name FROM users ORDER BY id")
  end

  test "test_connection/1 with valid profile returns :ok" do
    profile = %ConnectionProfile{id: "sqlite_test_2", name: "Test SQLite 2", driver: :sqlite, database: ":memory:"}
    assert :ok = ConnectionWorker.test_connection(profile)
  end

  test "test_connection/1 with running worker pid returns :ok" do
    profile = %ConnectionProfile{id: "sqlite_test_3", name: "Test SQLite 3", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)
    assert :ok = ConnectionWorker.test_connection(pid)
  end

  test "execute_query returns error on invalid SQL" do
    profile = %ConnectionProfile{id: "sqlite_test_4", name: "Test SQLite 4", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)
    assert {:error, _reason} = ConnectionWorker.execute_query(pid, "SELECT * FROM non_existent_table")
  end

  test "SSHTunnel returns error when connecting to unreachable host" do
    ssh_profile = %SSHProfile{id: "unreachable", name: "Unreachable", host: "127.0.0.1", port: 65530}
    assert {:error, _reason} = SSHTunnel.connect(ssh_profile, "127.0.0.1", 5432)
  end
end
