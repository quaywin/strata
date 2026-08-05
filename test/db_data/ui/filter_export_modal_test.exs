defmodule DBData.UI.Components.FilterExportModalTest do
  use ExUnit.Case, async: true
  alias DBData.UI.Components.FilterExportModal

  describe "new/2" do
    test "initializes filter modal state" do
      modal = FilterExportModal.new_filter(where: "status = 'active'", order_by: "id DESC", limit: 100)
      assert modal.mode == :filter
      assert modal.where_clause == "status = 'active'"
      assert modal.order_by_clause == "id DESC"
      assert modal.limit == 100
      assert modal.focused_field == :where
    end

    test "initializes export modal state" do
      modal = FilterExportModal.new_export(format: :csv, file_path: "users.csv", scope: :current_page)
      assert modal.mode == :export
      assert modal.format == :csv
      assert modal.file_path == "users.csv"
      assert modal.scope == :current_page
      assert modal.focused_field == :format
    end
  end

  describe "handle_key/2 field navigation and input" do
    test "navigates filter modal fields with tab and shift_tab" do
      modal = FilterExportModal.new_filter()
      assert modal.focused_field == :where

      modal = FilterExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :order_by

      modal = FilterExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :limit

      modal = FilterExportModal.handle_key(modal, :shift_tab)
      assert modal.focused_field == :order_by
    end

    test "cycles export format when format field is focused" do
      modal = FilterExportModal.new_export(format: :csv)
      modal = %{modal | focused_field: :format}

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :json

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :sql

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :csv
    end

    test "cycles export scope when scope field is focused" do
      modal = FilterExportModal.new_export(scope: :all)
      modal = %{modal | focused_field: :scope}

      modal = FilterExportModal.handle_key(modal, :space)
      assert modal.scope == :current_page

      modal = FilterExportModal.handle_key(modal, :space)
      assert modal.scope == :all
    end

    test "types text into focused filter/export inputs" do
      modal = FilterExportModal.new_filter(where: "id > 0", focused_field: :where)

      modal = FilterExportModal.handle_key(modal, " AND age >= 18")
      assert modal.where_clause == "id > 0 AND age >= 18"

      modal = FilterExportModal.handle_key(modal, :backspace)
      assert modal.where_clause == "id > 0 AND age >= 1"
    end
  end

  describe "build_filter_sql/2" do
    test "constructs SQL clause from filter settings" do
      modal = FilterExportModal.new_filter(
        where: "status = 'active'",
        order_by: "created_at DESC",
        limit: 50
      )

      sql_clause = FilterExportModal.build_filter_sql(modal, "users")
      assert sql_clause =~ "SELECT * FROM users"
      assert sql_clause =~ "WHERE status = 'active'"
      assert sql_clause =~ "ORDER BY created_at DESC"
      assert sql_clause =~ "LIMIT 50"
    end

    test "handles empty filter fields gracefully" do
      modal = FilterExportModal.new_filter()
      sql_clause = FilterExportModal.build_filter_sql(modal, "users")
      assert sql_clause == "SELECT * FROM users"
    end
  end

  describe "format_export/3" do
    test "formats data as CSV" do
      modal = FilterExportModal.new_export(format: :csv)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      csv = FilterExportModal.format_export(modal, cols, rows, table_name: "users")
      assert csv == "id,name\n1,Alice\n2,Bob\n"
    end

    test "formats data as JSON" do
      modal = FilterExportModal.new_export(format: :json)
      cols = ["id", "name"]
      rows = [["1", "Alice"]]

      json_str = FilterExportModal.format_export(modal, cols, rows)
      decoded = Jason.decode!(json_str)
      assert decoded == [%{"id" => "1", "name" => "Alice"}]
    end

    test "formats data as SQL INSERT statements" do
      modal = FilterExportModal.new_export(format: :sql)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      sql = FilterExportModal.format_export(modal, cols, rows, table_name: "users")
      assert sql =~ "INSERT INTO users (id, name) VALUES ('1', 'Alice');"
      assert sql =~ "INSERT INTO users (id, name) VALUES ('2', 'Bob');"
    end
  end

  describe "render/2" do
    test "returns structured map for rendering filter dialog" do
      modal = FilterExportModal.new_filter()
      rendered = FilterExportModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "FILTER"
      assert rendered.mode == :filter
      assert is_list(rendered.fields)
    end

    test "returns structured map for rendering export dialog" do
      modal = FilterExportModal.new_export()
      rendered = FilterExportModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "EXPORT"
      assert rendered.mode == :export
      assert is_list(rendered.fields)
    end
  end
end
