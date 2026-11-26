defmodule Strata.ConnectionWorkerTest do
  use ExUnit.Case
  alias Strata.{ConnectionWorker, ConnectionProfile, SSHTunnel, SSHProfile}

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

  test "SQLite adapter binds positional parameters safely" do
    profile = %ConnectionProfile{id: "sqlite_params", name: "Params SQLite", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)

    assert {:ok, %{rows: [[5]]}} = ConnectionWorker.execute_query(pid, "SELECT ? + ?", [2, 3])
  end

  test "ConnectionSupervisor reuses persistent ConnectionWorker across execute_query_for_profile calls" do
    profile = %ConnectionProfile{
      id: "persistent_sqlite_#{System.unique_integer([:positive])}",
      name: "Persistent SQLite",
      driver: :sqlite,
      database: ":memory:"
    }

    assert {:ok, _} = ConnectionWorker.execute_query_for_profile(profile, "CREATE TABLE items (id INTEGER, label TEXT)")
    assert {:ok, _} = ConnectionWorker.execute_query_for_profile(profile, "INSERT INTO items VALUES (1, 'hello')")

    assert {:ok, pid1} = Strata.ConnectionSupervisor.lookup_worker(profile.id)
    assert {:ok, %{rows: [[1, "hello"]]}} = ConnectionWorker.execute_query_for_profile(profile, "SELECT id, label FROM items")
    assert {:ok, ^pid1} = Strata.ConnectionSupervisor.lookup_worker(profile.id)

    assert :ok = Strata.ConnectionSupervisor.stop_worker(profile.id)
    assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(profile.id)
  end

  test "execute_transaction commits multi-statement batch and rolls back on failure" do
    profile = %ConnectionProfile{id: "tx_sqlite", name: "TX SQLite", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)
    on_exit(fn -> ConnectionWorker.stop(pid) end)

    assert {:ok, _} = ConnectionWorker.execute_query(pid, "CREATE TABLE ledger (id INTEGER PRIMARY KEY, val TEXT)")

    # Successful transaction batch
    assert {:ok, 2} =
             ConnectionWorker.execute_transaction(pid, [
               {"INSERT INTO ledger (id, val) VALUES (?, ?)", [1, "first"]},
               {"UPDATE ledger SET val = ? WHERE id = ?", ["updated", 1]}
             ])

    assert {:ok, %{rows: [[1, "updated"]]}} = ConnectionWorker.execute_query(pid, "SELECT id, val FROM ledger")

    # Failing second statement rolls back first statement inside same batch
    assert {:error, _reason} =
             ConnectionWorker.execute_transaction(pid, [
               {"INSERT INTO ledger (id, val) VALUES (?, ?)", [2, "second"]},
               {"INSERT INTO ledger (id, val) VALUES (?, ?)", [1, "duplicate_pk"]}
             ])

    assert {:ok, %{rows: [[1, "updated"]]}} = ConnectionWorker.execute_query(pid, "SELECT id, val FROM ledger")
  end

  test "returns {:ssh_tunnel_failed, _} instead of falling back when SSH profile is missing or unreachable" do
    missing_ssh = %ConnectionProfile{
      id: "missing_ssh_#{System.unique_integer([:positive])}",
      name: "Missing SSH",
      driver: :sqlite,
      database: ":memory:",
      ssh_profile_id: "nonexistent_ssh_id"
    }

    assert {:error, {:ssh_tunnel_failed, _}} = ConnectionWorker.test_connection(missing_ssh)
  end
end
