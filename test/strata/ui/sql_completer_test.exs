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

    test "returns empty list when prefix is empty" do
      assert SQLCompleter.suggestions("") == []
    end
  end

  describe "apply_completion" do
    test "replaces prefix with suggestion insert text and updates cursor" do
      content = "SELECT * FROM us"
      suggestion = %{label: "users", type: :table, insert_text: "users"}
      
      {updated_content, new_cursor} = SQLCompleter.apply_completion(content, {0, 16}, suggestion, "us")
      assert updated_content == "SELECT * FROM users"
      assert new_cursor == {0, 19}
    end
  end
end
