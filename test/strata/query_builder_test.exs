defmodule Strata.QueryBuilderTest do
  use ExUnit.Case, async: true

  alias Strata.QueryBuilder

  describe "coerce_value/2" do
    test "coerces numeric and boolean edits back to original scalar types" do
      assert QueryBuilder.coerce_value("42", 10) == 42
      assert QueryBuilder.coerce_value("3.14", 1.5) == 3.14
      assert QueryBuilder.coerce_value("true", false) == true
      assert QueryBuilder.coerce_value("0", true) == false
      assert QueryBuilder.coerce_value("Alice", "Bob") == "Alice"
      assert QueryBuilder.coerce_value(nil, 10) == nil
      # Unparseable integer stays string so database validation handles it
      assert QueryBuilder.coerce_value("abc", 10) == "abc"
    end
  end

  describe "build_update/6 and build_delete/5" do
    test "generates Postgres $1..$n parameterized UPDATE and DELETE using primary key" do
      cols = ["id", "name", "email"]
      orig = [7, "Alice", "a@test.com"]

      assert {:ok, {update_sql, update_params}} =
               QueryBuilder.build_update(
                 :postgres,
                 ~s["public"."users"],
                 cols,
                 orig,
                 %{1 => "Alicia"},
                 ["id"]
               )

      assert update_sql == ~s[UPDATE "public"."users" SET "name" = $1 WHERE "id" = $2;]
      assert update_params == ["Alicia", 7]

      assert {:ok, {del_sql, del_params}} =
               QueryBuilder.build_delete(:postgres, ~s["public"."users"], cols, orig, ["id"])

      assert del_sql == ~s[DELETE FROM "public"."users" WHERE "id" = $1;]
      assert del_params == [7]
    end

    test "falls back to all original columns with IS NULL when primary key is missing" do
      cols = ["id", "name", "note"]
      orig = [1, "Alice", nil]

      assert {:ok, {sql, params}} =
               QueryBuilder.build_update(:sqlite, ~s["logs"], cols, orig, %{1 => "Bob"}, [])

      assert sql ==
               ~s[UPDATE "logs" SET "name" = ? WHERE "id" = ? AND "name" = ? AND "note" IS NULL;]

      assert params == ["Bob", 1, "Alice"]
    end
  end

  describe "build_insert/4 and build_batch/5" do
    test "omits nil columns in INSERT and emits DEFAULT VALUES when all nil" do
      cols = ["id", "name", "role"]

      assert {:ok, {sql, params}} =
               QueryBuilder.build_insert(:sqlite, ~s["users"], cols, [nil, "Eve", "Admin"])

      assert sql == ~s[INSERT INTO "users" ("name", "role") VALUES (?, ?);]
      assert params == ["Eve", "Admin"]

      assert {:ok, {blank_sql, []}} =
               QueryBuilder.build_insert(:postgres, ~s["users"], cols, [nil, nil, nil])

      assert blank_sql == ~s[INSERT INTO "users" DEFAULT VALUES;]

      assert {:ok, {mysql_blank_sql, []}} =
               QueryBuilder.build_insert(:mysql, "`users`", cols, [nil, nil, nil])

      assert mysql_blank_sql == "INSERT INTO `users` () VALUES ();"
    end

    test "build_batch orders UPDATE, INSERT, DELETE and skips edits on deleted rows" do
      cols = ["id", "name"]
      rows = [[1, "Alice"], [2, "Bob"]]

      edits = %{
        {0, 1} => %{orig: "Alice", new: "Alicia"},
        # Row 1 is also marked deleted -> edit should be skipped
        {1, 1} => %{orig: "Bob", new: "Bobby"}
      }

      inserts = [[nil, "Charlie"]]
      deletes = MapSet.new([1])

      assert {:ok, stmts} =
               QueryBuilder.build_batch(:mysql, "`users`", cols, rows,
                 pending_edits: edits,
                 pending_inserts: inserts,
                 pending_deletes: deletes,
                 primary_keys: ["id"]
               )

      assert stmts == [
               {"UPDATE `users` SET `name` = ? WHERE `id` = ?;", ["Alicia", 1]},
               {"INSERT INTO `users` (`name`) VALUES (?);", ["Charlie"]},
               {"DELETE FROM `users` WHERE `id` = ?;", [2]}
             ]
    end
  end

  describe "build_filter_select/5" do
    test "builds parameterized * All global search and column/operator filters across drivers" do
      cols = ["id", "name", "email"]

      # Postgres uses $1 reuse across OR clauses + ILIKE + ESCAPE '!'
      assert {:ok, {pg_sql, pg_params}} =
               QueryBuilder.build_filter_select(:postgres, ~s["public"."users"], cols, %{
                 mode: :builder,
                 column: "* All",
                 op: :contains,
                 value: "100%_test"
               })

      assert pg_sql ==
               ~s[SELECT * FROM "public"."users" WHERE (CAST("id" AS TEXT) ILIKE $1 ESCAPE '!' OR CAST("name" AS TEXT) ILIKE $1 ESCAPE '!' OR CAST("email" AS TEXT) ILIKE $1 ESCAPE '!') LIMIT 200;]

      assert pg_params == ["%100!%!_test%"]

      # MySQL duplicates ? placeholder across columns + CAST AS CHAR
      assert {:ok, {my_sql, my_params}} =
               QueryBuilder.build_filter_select(:mysql, "`users`", cols, %{
                 mode: :builder,
                 column: "* All",
                 op: :starts_with,
                 value: "al"
               })

      assert my_sql ==
               "SELECT * FROM `users` WHERE (CAST(`id` AS CHAR) LIKE ? ESCAPE '!' OR CAST(`name` AS CHAR) LIKE ? ESCAPE '!' OR CAST(`email` AS CHAR) LIKE ? ESCAPE '!') LIMIT 200;"

      assert my_params == ["al%", "al%", "al%"]

      # Single-column scalar filter coerces integer against sample_row
      assert {:ok, {eq_sql, eq_params}} =
               QueryBuilder.build_filter_select(
                 :sqlite,
                 ~s["users"],
                 cols,
                 %{mode: :builder, column: "id", op: :>=, value: "42"},
                 sample_row: [1, "Alice", "a@b.c"]
               )

      assert eq_sql == ~s[SELECT * FROM "users" WHERE "id" >= ? LIMIT 200;]
      assert eq_params == [42]

      # IS NULL emits parameterless NULL check
      assert {:ok, {null_sql, []}} =
               QueryBuilder.build_filter_select(:postgres, ~s["users"], cols, %{
                 mode: :builder,
                 column: "email",
                 op: :is_null,
                 value: ""
               })

      assert null_sql == ~s[SELECT * FROM "users" WHERE "email" IS NULL LIMIT 200;]
    end
  end

  describe "paginate_select_query/3" do
    test "wraps un-limited SELECT and CTE queries with LIMIT + 1 for has_more detection" do
      assert {:paginated, wrapped, 100} =
               QueryBuilder.paginate_select_query(
                 "SELECT * FROM users WHERE active = true;",
                 100,
                 0
               )

      assert wrapped ==
               "SELECT * FROM (SELECT * FROM users WHERE active = true) AS _strata_page LIMIT 101 OFFSET 0"

      assert {:paginated, cte_wrapped, 50} =
               QueryBuilder.paginate_select_query(
                 "WITH active_u AS (SELECT * FROM users LIMIT 10) SELECT * FROM active_u",
                 50,
                 50
               )

      assert cte_wrapped ==
               "SELECT * FROM (WITH active_u AS (SELECT * FROM users LIMIT 10) SELECT * FROM active_u) AS _strata_page LIMIT 51 OFFSET 50"
    end

    test "passes through queries with user LIMIT, non-SELECT, or multi-statement SQL" do
      assert :passthrough = QueryBuilder.paginate_select_query("SELECT * FROM users LIMIT 25;")

      assert :passthrough =
               QueryBuilder.paginate_select_query("SELECT * FROM users FETCH FIRST 10 ROWS ONLY")

      assert :passthrough = QueryBuilder.paginate_select_query("DELETE FROM users WHERE id = 1;")
      assert :passthrough = QueryBuilder.paginate_select_query("EXPLAIN SELECT * FROM users;")
      assert :passthrough = QueryBuilder.paginate_select_query("SELECT 1; SELECT 2;")
    end
  end
end
