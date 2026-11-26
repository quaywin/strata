defmodule Strata.AdapterTest do
  use ExUnit.Case, async: true

  alias Strata.Adapter
  alias Strata.Adapter.{MySQL, Postgres, SQLite}

  describe "Adapter Registry and Resolution" do
    test "returns list of supported drivers" do
      assert Adapter.supported_drivers() == [:postgres, :mysql, :sqlite]
    end

    test "resolves driver atom and string to correct Adapter module" do
      assert Adapter.for_driver(:postgres) == Postgres
      assert Adapter.for_driver("postgres") == Postgres
      assert Adapter.for_driver("postgresql") == Postgres

      assert Adapter.for_driver(:mysql) == MySQL
      assert Adapter.for_driver("mysql") == MySQL
      assert Adapter.for_driver("mariadb") == MySQL

      assert Adapter.for_driver(:sqlite) == SQLite
      assert Adapter.for_driver("sqlite3") == SQLite
    end

    test "raises ArgumentError for unsupported drivers" do
      assert_raise ArgumentError, fn ->
        Adapter.for_driver(:oracle)
      end
    end

    test "returns default ports for drivers" do
      assert Adapter.default_port(:postgres) == 5432
      assert Adapter.default_port(:mysql) == 3306
      assert Adapter.default_port(:sqlite) == 0
      assert Adapter.default_port(:unknown) == 0
    end

    test "quotes SQL identifiers safely per driver" do
      assert Adapter.quote_identifier(:postgres, "users") == ~s("users")
      assert Adapter.quote_identifier(:postgres, ~s(my"table)) == ~s("my""table")
      assert Adapter.quote_identifier(:sqlite, ~s(a"b)) == ~s("a""b")
      assert Adapter.quote_identifier(:mysql, "my`table") == "`my``table`"
    end
  end
end
