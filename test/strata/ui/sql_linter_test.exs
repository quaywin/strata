defmodule Strata.UI.Components.SQLLinterTest do
  use ExUnit.Case, async: true

  alias Strata.UI.Components.SQLLinter

  @table_cols %{
    "users" => ["id", "email", "name"],
    "orders" => ["id", "user_id", "total"]
  }

  describe "check/2" do
    test "returns empty list for valid SQL against cached schema" do
      sql = "SELECT u.id, u.email FROM users u WHERE u.name = 'Alice';"
      assert SQLLinter.check(sql, table_columns: @table_cols) == []
    end

    test "detects unclosed parenthesis and unclosed string literal" do
      diags = SQLLinter.check("SELECT * FROM users WHERE (name = 'Alice")
      messages = Enum.map(diags, & &1.message)

      assert Enum.any?(messages, &(&1 =~ "Unclosed string literal"))
      assert Enum.any?(messages, &(&1 =~ "Unclosed parenthesis"))
    end

    test "detects unknown alias/qualifier and unknown column in cached tables" do
      sql = "SELECT u.id FROM users u WHERE x.id = 1 AND u.non_existent = 'a';"
      diags = SQLLinter.check(sql, table_columns: @table_cols)
      messages = Enum.map(diags, & &1.message)

      assert "Unknown table/alias 'x'" in messages
      assert "Column 'non_existent' not found in 'users'" in messages
    end

    test "detects unknown unqualified column in WHERE when all referenced tables are cached" do
      sql = "SELECT id FROM users WHERE emai = 'a@b.com';"
      diags = SQLLinter.check(sql, table_columns: @table_cols)
      assert Enum.any?(diags, &(&1.message == "Unknown column 'emai'"))
    end

    test "warns when DELETE or UPDATE lacks WHERE clause" do
      del_diags = SQLLinter.check("DELETE FROM users;")

      assert Enum.any?(
               del_diags,
               &(&1.severity == :warning and &1.message =~ "DELETE without WHERE")
             )

      upd_diags = SQLLinter.check("UPDATE users SET name = 'Bob';")

      assert Enum.any?(
               upd_diags,
               &(&1.severity == :warning and &1.message =~ "UPDATE without WHERE")
             )
    end
  end
end
