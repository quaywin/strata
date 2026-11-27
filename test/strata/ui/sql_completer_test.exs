defmodule Strata.UI.Components.SQLCompleterTest do
  use ExUnit.Case, async: true

  alias Strata.UI.Components.SQLCompleter

  describe "extract_prefix" do
    test "extracts prefix word before cursor" do
      content = "SELECT * FROM us"
      {prefix, start_col} = SQLCompleter.extract_prefix(content, {0, 16})
      assert prefix == "us"
      assert start_col == 14
    end

    test "returns empty string when at whitespace or boundary" do
      content = "SELECT "
      {prefix, start_col} = SQLCompleter.extract_prefix(content, {0, 7})
      assert prefix == ""
      assert start_col == 7
    end
  end

  describe "suggestions" do
    test "matches SQL keywords" do
      results = SQLCompleter.suggestions("SE")
      labels = Enum.map(results, & &1.label)

      assert "SELECT" in labels
      assert "SET" in labels
    end

    test "matches schema tables when sidebar_nodes provided" do
      nodes = [
        %{
          id: "conn_1",
          label: "Connection 1",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "conn_1_schema_public",
              label: "public",
              type: :schema,
              expanded?: true,
              children: [
                %{id: "conn_1_tbl_users", label: "users", type: :table, children: []},
                %{id: "conn_1_tbl_orders", label: "orders", type: :table, children: []}
              ]
            }
          ]
        }
      ]

      results = SQLCompleter.suggestions("us", sidebar_nodes: nodes)
      labels = Enum.map(results, & &1.label)

      assert "users" in labels
    end

    test "extracts tables even when parent connection or schema node is collapsed" do
      nodes = [
        %{
          id: "conn_collapsed",
          label: "Collapsed DB",
          type: :connection,
          expanded?: false,
          children: [
            %{
              id: "schema_collapsed",
              label: "public",
              type: :schema,
              expanded?: false,
              children: [
                %{id: "tbl_invoices", label: "invoices", type: :table, children: []}
              ]
            }
          ]
        }
      ]

      results = SQLCompleter.suggestions("inv", sidebar_nodes: nodes)
      assert Enum.any?(results, &(&1.label == "invoices"))
    end

    test "returns empty list when prefix is empty" do
      assert SQLCompleter.suggestions("") == []
    end

    test "suggests columns for referenced tables and supports table/alias dot-completion" do
      table_cols = %{
        "users" => ["id", "email", "created_at"],
        "orders" => ["id", "user_id", "total"]
      }

      # Referenced table column completion without qualifier uses alias `u.email` with source detail
      res_unqual =
        SQLCompleter.suggestions("em",
          table_columns: table_cols,
          sql: "SELECT em FROM users u"
        )

      assert Enum.any?(
               res_unqual,
               &(&1.type == :column and &1.insert_text == "u.email" and
                   &1.detail == "users → email")
             )

      # Alias dot-completion: `u.cr` -> `u.created_at`
      res_alias =
        SQLCompleter.suggestions("u.cr",
          table_columns: table_cols,
          sql: "SELECT * FROM users u WHERE u.cr"
        )

      assert [%{label: "u.created_at", type: :column, insert_text: "u.created_at"}] = res_alias

      # Table dot-completion: `orders.` lists orders columns
      res_dot =
        SQLCompleter.suggestions("orders.",
          table_columns: table_cols,
          sql: "SELECT * FROM orders WHERE orders."
        )

      labels = Enum.map(res_dot, & &1.label)
      assert "orders.user_id" in labels
      assert "orders.total" in labels
      assert Enum.all?(res_dot, &(&1.detail =~ "orders →"))
    end

    test "clause-aware completion isolates statements by semicolon and provides auto-alias in FROM/JOIN" do
      nodes = [
        %{
          id: "conn_1",
          label: "DB",
          type: :connection,
          children: [
            %{
              id: "sch",
              label: "public",
              type: :schema,
              children: [
                %{id: "t1", label: "users", type: :table, children: []},
                %{id: "t2", label: "order_items", type: :table, children: []}
              ]
            }
          ]
        }
      ]

      table_cols = %{
        "users" => ["id", "email"],
        "order_items" => ["id", "order_id", "sku"]
      }

      # In FROM clause with empty prefix -> returns ONLY tables + auto-alias options
      from_sql = "SELECT * FROM "

      from_suggs =
        SQLCompleter.suggestions("",
          sidebar_nodes: nodes,
          table_columns: table_cols,
          sql: from_sql,
          cursor: {0, String.length(from_sql)},
          allow_empty_prefix: true
        )

      assert Enum.all?(from_suggs, &(&1.type == :table))
      assert Enum.any?(from_suggs, &(&1.insert_text == "users u"))
      assert Enum.any?(from_suggs, &(&1.insert_text == "order_items oi"))

      # Second statement after semicolon ignores `users` from first statement
      multi_sql = "SELECT * FROM users u;\nSELECT * FROM order_items oi WHERE "

      where_suggs =
        SQLCompleter.suggestions("",
          sidebar_nodes: nodes,
          table_columns: table_cols,
          sql: multi_sql,
          cursor: {1, String.length("SELECT * FROM order_items oi WHERE ")},
          allow_empty_prefix: true
        )

      assert Enum.all?(where_suggs, &(&1.type == :column))

      assert Enum.any?(
               where_suggs,
               &(&1.insert_text == "oi.sku" and &1.detail == "order_items → sku")
             )

      refute Enum.any?(where_suggs, &(&1.insert_text =~ "email"))

      # Two unaliased tables auto-qualify table.col to prevent ambiguity
      join_sql = "SELECT * FROM users JOIN order_items ON "

      join_suggs =
        SQLCompleter.suggestions("",
          sidebar_nodes: nodes,
          table_columns: table_cols,
          sql: join_sql,
          cursor: {0, String.length(join_sql)},
          allow_empty_prefix: true
        )

      assert Enum.any?(join_suggs, &(&1.insert_text == "users.email"))
      assert Enum.any?(join_suggs, &(&1.insert_text == "order_items.order_id"))

      # Fuzzy matching finds subsequence columns (e.g. `ordid` -> `order_id`)
      fuzzy =
        SQLCompleter.suggestions("ordid",
          sidebar_nodes: nodes,
          table_columns: table_cols,
          sql: "SELECT * FROM order_items WHERE ordid",
          cursor: {0, 37}
        )

      assert Enum.any?(fuzzy, &(&1.insert_text == "order_id"))
    end
  end

  describe "apply_completion" do
    test "replaces prefix with suggestion insert text and updates cursor" do
      content = "SELECT * FROM us"
      suggestion = %{label: "users", type: :table, insert_text: "users"}

      {updated_content, new_cursor} =
        SQLCompleter.apply_completion(content, {0, 16}, suggestion, "us")

      assert updated_content == "SELECT * FROM users"
      assert new_cursor == {0, 19}
    end
  end
end
